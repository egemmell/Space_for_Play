# =============================================================================
# Space for Play Indicators
# =============================================================================
# Calculates formal play space indicators using CanMap and OpenStreetMap data.
# Includes:
#   1. Filtering and saving CanMap park polygons per CMA
#   2. Downloading OSM park polygons per CMA
#   3. Combining CanMap + OSM parks and counting parks within 500m of each
#      postal code centroid
#
# Data sources:
#   - CanMap Content Suite 2020 v.3 (park polygons)
#   - OpenStreetMap (park polygons, leisure: park/playground/dog_park/common)
#   - CanMap postal code shapefiles per CMA
#
# CRS conventions:
#   - EPSG:3347 (Statistics Canada Lambert) for all spatial operations
#   - EPSG:4326 (WGS84) only where required: OSM queries, st_crop input
#
# Output: CSV files with park counts per postal code, one per CMA
# =============================================================================

library(sf)
library(tidyverse)
library(osmdata)
library(lwgeom)

load("Data/CMAcodes")

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

PARK_CLASSES <- c(
  "PARK/SPORTS FIELD", "RECREATION",          "DAY USE",
  "BOTANICAL GARDEN",  "NATURAL ENVIRONMENT", "PICNIC SITE",
  "NATURE RESERVE",    "RECREATION AREA",     "PROVINCIAL PARK",
  "NATURAL AREA",      "PARK RESERVE"
)

# OSM key and values for park features
OSM_KEY          <- "leisure"
OSM_VALUES       <- c("park", "playground", "dog_park", "common")
MIN_PARK_AREA_M2 <- 100          # minimum park area in m²; filters OSM sub-features
OSM_FILE_PREFIX  <- "osmpk03132026_"   # filename prefix for saved OSM shapefiles

OSM_OUT_DIR <- "Data/Space_for_Play_Dimension/OSMparks"
dir.create(OSM_OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

# Build a WGS84 bounding box extended 1000m beyond the CMA extent.
# Buffering is done in EPSG:3347 for accurate metre-based distances;
# the result is converted back to WGS84 for use with st_crop() and opq().
cma_bbox_wgs84 <- function(postal_codes_shp) {
  postal_codes_shp |>
    st_transform(3347) |>
    st_buffer(1000) |>    # true 1000m buffer in projected CRS
    st_union() |>         # dissolve to single CMA extent
    st_transform(4326) |>
    st_bbox()
}

# Extract and clean one OSM polygon layer; return NULL if absent.
# OSM data arrives in WGS84; results are reprojected to EPSG:3347.
# The key parameter matches the OSM key used in the query (e.g. "leisure"),
# ensuring the correct column is used for filtering.
# min_area_m2: minimum polygon area in m² to retain (default 100m²) —
# filters out sub-features tagged within parks (benches, path segments etc.)
# while keeping even very small playgrounds.
extract_osm_polygons <- function(osm_result,
                                 layer = c("osm_polygons", "osm_multipolygons"),
                                 key,
                                 values,
                                 min_area_m2 = MIN_PARK_AREA_M2) {
  layer <- match.arg(layer)
  geom  <- osm_result[[layer]]
  
  if (is.null(geom) || nrow(geom) == 0) return(NULL)
  
  geom <- geom |>
    st_transform(3347) |>          # OSM is always WGS84; project for analysis
    st_make_valid() |>
    filter(!is.na(.data[[key]]), .data[[key]] %in% values) |>
    mutate(area_m2 = as.numeric(st_area(geometry))) |>
    filter(area_m2 >= min_area_m2) |>   # exclude sub-features smaller than threshold
    select(osm_id)
  
  if (nrow(geom) == 0) return(NULL)
  
  geom
}

# -----------------------------------------------------------------------------
# SECTION 1: Filter and save CanMap park polygons per CMA
# -----------------------------------------------------------------------------
# National CanMap parks are filtered to relevant classes, then cropped to each
# CMA study area (+ 1000m) and saved in EPSG:3347.

parks_national <- st_read(
  "Data/Space_for_Play_Dimension/CANMAP parks/ParksSportsFieldRegion.shp"
) |>
  st_transform(3347) |>
  filter(CLASS %in% PARK_CLASSES) |>
  mutate(parks = 1) |>
  select(parks)

st_write(parks_national,
         "Data/Space_for_Play_Dimension/CANMAP parks/bigpark.shp",
         delete_dsn = TRUE)

for (cma in CMAcodes) {
  message("\n── CanMap parks, CMA: ", cma, " ──────────────────────────")
  
  postal_codes <- st_read(paste0("Data/CanMapPC/CMAPC", cma, ".shp"),
                          quiet = TRUE)
  
  bbox_wgs84 <- cma_bbox_wgs84(postal_codes)
  
  # st_crop requires matching CRS: temporarily convert to WGS84, crop,
  # then reproject back to 3347 for saving
  parks_cma <- parks_national |>
    st_transform(4326) |>
    st_crop(bbox_wgs84) |>
    st_transform(3347)
  
  write_sf(parks_cma,
           paste0("Data/Space_for_Play_Dimension/CANMAP parks/cmapks", cma, ".shp"),
           delete_dsn = TRUE)
  
  message("  CanMap parks saved: ", nrow(parks_cma))
  rm(postal_codes, bbox_wgs84, parks_cma)
  gc()
}

# -----------------------------------------------------------------------------
# SECTION 2: Download OSM park polygons per CMA
# -----------------------------------------------------------------------------
# opq() requires a WGS84 bbox. We build a +1000m buffered bbox in 3347,
# convert to WGS84 for the query, then immediately reproject results to 3347.
# Geometries are kept in their native type (POLYGON or MULTIPOLYGON) —
# multipolygons are NOT split so each OSM feature counts as one distinct park.
# Features smaller than MIN_PARK_AREA_M2 are filtered out to remove OSM
# sub-features (benches, path segments etc.) incorrectly tagged as parks.

for (cma in CMAcodes) {
  message("\n── OSM parks, CMA: ", cma, " ─────────────────────────────")
  
  postal_codes <- st_read(paste0("Data/CanMapPC/CMAPC", cma, ".shp"),
                          quiet = TRUE)
  
  bbox_wgs84 <- cma_bbox_wgs84(postal_codes)
  
  message("  Querying OSM (key: ", OSM_KEY, ")...")
  osm_raw <- tryCatch({
    q <- opq(bbox = bbox_wgs84) |>        # opq() requires WGS84
      add_osm_feature(key = OSM_KEY, value = OSM_VALUES)
    osmdata::osmdata_sf(q) |>             # explicit namespace avoids scoping issues
      osmdata::unique_osmdata()           # disaggregates merged multipolygons into individual features
  },
  error = function(e) {
    warning("  OSM query failed for CMA ", cma, ": ", conditionMessage(e))
    NULL
  })
  
  if (is.null(osm_raw)) next
  
  layers <- list(
    extract_osm_polygons(osm_raw, "osm_polygons",      key = OSM_KEY, values = OSM_VALUES, min_area_m2 = MIN_PARK_AREA_M2),
    extract_osm_polygons(osm_raw, "osm_multipolygons", key = OSM_KEY, values = OSM_VALUES, min_area_m2 = MIN_PARK_AREA_M2)
  ) |>
    purrr::compact()
  
  if (length(layers) == 0) {
    message("  No park polygons found — skipping.")
    next
  }
  
  parks_osm <- bind_rows(layers) |>
    distinct(osm_id, .keep_all = TRUE)    # one row = one distinct park
  
  message("  Distinct OSM parks retained: ", nrow(parks_osm))
  
  write_sf(parks_osm,
           file.path(OSM_OUT_DIR, paste0(OSM_FILE_PREFIX, cma, ".shp")),
           delete_dsn = TRUE)
  
  rm(postal_codes, bbox_wgs84, osm_raw, layers, parks_osm)
  gc()
}

# -----------------------------------------------------------------------------
# SECTION 3: Merge CanMap + OSM parks; count distinct parks within 500m
# -----------------------------------------------------------------------------
# Both datasets are in EPSG:3347 at this point.
# sf_use_s2(FALSE) ensures planar (GEOS) geometry, consistent with EPSG:3347.
#
# OSM dissolve strategy:
#   - Large parks are often mapped as many overlapping sub-features in OSM
#     (individual sports fields, playgrounds, garden beds etc.), each with a
#     unique osm_id. Without dissolving, these inflate the park count.
#   - st_union() merges all touching/overlapping OSM polygons, then
#     st_cast("POLYGON") splits the result into spatially disconnected clusters.
#   - Each cluster = one distinct park location for counting purposes.
#   - osm_cluster_id identifies each dissolved cluster in the output CSV.
#
# Deduplication strategy:
#   - st_join(osm_parks_dissolved, canmap_parks) can produce multiple rows if
#     a dissolved cluster overlaps more than one CanMap polygon.
#   - distinct(osm_cluster_id) collapses these back to one row per cluster.

sf_use_s2(FALSE)

for (cma in CMAcodes) {
  message("\n── Counting parks, CMA: ", cma, " ──────────────────────────")
  
  # --- Load data (already in EPSG:3347) --------------------------------------
  canmap_parks <- st_read(
    paste0("Data/Space_for_Play_Dimension/CANMAP parks/cmapks", cma, ".shp"),
    quiet = TRUE
  ) |>
    mutate(cm_id = row_number()) |>
    select(cm_id)
  
  osm_parks <- st_read(
    file.path(OSM_OUT_DIR, paste0(OSM_FILE_PREFIX, cma, ".shp")),
    quiet = TRUE
  ) |>
    select(osm_id)
  
  message("  CanMap parks loaded:            ", nrow(canmap_parks))
  message("  OSM parks loaded:               ", nrow(osm_parks))
  
  postal_codes <- st_read(paste0("Data/CanMapPC/CMAPC", cma, ".shp"),
                          quiet = TRUE) |>
    st_transform(3347)
  
  # --- Dissolve touching/overlapping OSM parks into distinct clusters ---------
  # Large parks mapped as many sub-features (sports fields, playgrounds etc.)
  # are merged into single polygons. Each spatially disconnected cluster of
  # touching/overlapping polygons becomes one row = one distinct park location.
  osm_parks_dissolved <- osm_parks |>
    st_union() |>                      # merge all touching/overlapping polygons
    st_cast("MULTIPOLYGON") |>         # ensure consistent type before splitting
    st_cast("POLYGON") |>              # split into disconnected clusters
    st_as_sf() |>
    st_set_geometry("geometry") |>     # rename default "x" column to "geometry"
    mutate(osm_cluster_id = row_number())
  
  message("  OSM parks after dissolve:       ", nrow(osm_parks_dissolved))
  message("  OSM features merged:            ", nrow(osm_parks) - nrow(osm_parks_dissolved))
  
  # --- Map original osm_ids back to each dissolved cluster -------------------
  # After dissolving, we recover which original OSM features belong to each
  # cluster by spatially joining the original polygons onto the dissolved ones.
  # This preserves full traceability from cluster -> original osm_ids.
  osm_cluster_members <- st_join(
    osm_parks_dissolved,               # dissolved clusters (left)
    osm_parks |> select(osm_id),       # original features with their osm_ids (right)
    join = st_intersects
  ) |>
    st_drop_geometry() |>
    group_by(osm_cluster_id) |>
    summarise(
      osm_ids = paste(na.omit(unique(osm_id)), collapse = ";"),
      .groups = "drop"
    )
  
  # --- Build 500m buffers around postal code centroids -----------------------
  pc_buffers <- st_buffer(postal_codes, 500)
  
  # --- Combine dissolved OSM parks with CanMap parks -------------------------
  # Spatial join gives each dissolved OSM cluster the cm_id of any overlapping
  # CanMap park. distinct(osm_cluster_id) ensures a cluster overlapping multiple
  # CanMap polygons is counted only once.
  joined <- st_join(osm_parks_dissolved, canmap_parks)
  message("  Rows after st_join (pre-dedup): ", nrow(joined))
  
  all_parks <- joined |>
    distinct(osm_cluster_id, .keep_all = TRUE) |>   # one row per dissolved cluster
    mutate(id = row_number()) |>
    select(id, osm_cluster_id, cm_id) |>             # retain IDs for traceability
    st_make_valid()
  
  message("  Rows after dedup (post-dedup):  ", nrow(all_parks))
  message("  Duplicate rows removed:         ", nrow(joined) - nrow(all_parks))
  
  # --- Count distinct parks per postal code buffer ---------------------------
  # park_row indexes into all_parks; use it to look up all IDs for the output
  intersections <- st_intersects(pc_buffers, all_parks, sparse = TRUE) |>
    as.data.frame() |>
    setNames(c("buf_row", "park_row"))
  
  # Attach osm_cluster_id, original osm_ids, and cm_id to each intersection row
  park_ids <- all_parks |>
    st_drop_geometry() |>
    mutate(park_row = row_number()) |>
    left_join(osm_cluster_members, by = "osm_cluster_id") |>  # recover original osm_ids
    select(park_row, osm_cluster_id, osm_ids, cm_id)
  
  pc_lookup <- postal_codes |>
    st_drop_geometry() |>
    mutate(buf_row = row_number()) |>
    select(pc_id = 1, buf_row)   # assumes first column is the postal code ID
  
  park_counts <- pc_lookup |>
    left_join(intersections, by = "buf_row") |>
    left_join(park_ids, by = "park_row") |>
    mutate(has_park = as.integer(!is.na(park_row))) |>
    group_by(pc_id) |>
    summarise(
      parks          = sum(has_park),
      osm_cluster_id = paste(na.omit(unique(osm_cluster_id)), collapse = ";"),
      osm_ids        = paste(na.omit(unique(osm_ids)),        collapse = ";"),
      cm_id          = paste(na.omit(unique(cm_id)),          collapse = ";"),
      .groups = "drop"
    )
  
  write_csv(park_counts,
            paste0("Data/Space_for_Play_Dimension/all_parks", cma, ".csv"))
  
  message("  Postal codes processed: ", nrow(park_counts))
  
  rm(canmap_parks, osm_parks, osm_parks_dissolved, osm_cluster_members,
     postal_codes, pc_buffers, joined, all_parks, park_ids,
     intersections, pc_lookup, park_counts)
  gc()
}

message("\nDone.")
sf_use_s2()


################################################################################################
# =============================================================================
# Sanity Check: Top 6 Postal Codes by Park Count
# =============================================================================
# For a given CMA, identifies the 6 postal codes with the most parks, recovers
# the OSM park polygons associated with each, dissolves overlapping features,
# and plots all 6 in a single patchwork figure with OSM basemaps.
#
# Usage: set CMA and file paths at the top, then run the full script.
# =============================================================================

library(sf)
library(tidyverse)
library(ggspatial)
library(gridExtra)   # install.packages("gridExtra") if needed

# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------
CMA          <- 535
PARKS_CSV    <- paste0("Data/Space_for_Play_Dimension/all_parks", CMA, ".csv")
OSM_SHP      <- paste0("Data/Space_for_Play_Dimension/OSMparks/osmpk03132026_", CMA, ".shp")
PC_SHP       <- paste0("Data/CanMapPC/CMAPC", CMA, ".shp")
N_TOP        <- 6     # number of postal codes to plot

# -----------------------------------------------------------------------------
# Load data
# -----------------------------------------------------------------------------
allparks <- read_csv(PARKS_CSV, show_col_types = FALSE)
parks_osm <- st_read(OSM_SHP, quiet = TRUE)
postal_codes <- st_read(PC_SHP, quiet = TRUE) |> st_transform(4326)

# -----------------------------------------------------------------------------
# Identify top N postal codes by park count
# -----------------------------------------------------------------------------
top_pcs <- allparks |>
  arrange(desc(parks)) |>
  slice_head(n = N_TOP)

message("Top ", N_TOP, " postal codes by park count:")
print(top_pcs |> select(pc_id, parks))

# -----------------------------------------------------------------------------
# Helper: build one plot for a single postal code
# -----------------------------------------------------------------------------
plot_pc_parks <- function(pc_row, parks_osm, postal_codes) {
  
  pc_id    <- pc_row$pc_id
  n_parks  <- pc_row$parks
  
  # Parse semicolon-separated osm_ids from the CSV
  osm_ids  <- str_split(pc_row$osm_ids, ";")[[1]] |> trimws()
  
  # Filter OSM park polygons to those associated with this postal code
  pks <- parks_osm |>
    filter(osm_id %in% osm_ids) |>
    st_transform(4326)
  
  if (nrow(pks) == 0) {
    message("  No OSM parks found for PC: ", pc_id)
    return(NULL)
  }
  
  # Dissolve overlapping/touching polygons into distinct park clusters
  pks_dissolved <- pks |>
    st_union() |>
    st_cast("MULTIPOLYGON") |>
    st_cast("POLYGON") |>
    st_as_sf() |>
    st_set_geometry("geometry") |>
    mutate(osm_cluster_id = row_number())
  
  # Get postal code boundary — use the name of the first column as the PC ID field
  pc_id_col <- names(postal_codes)[1]
  pc_geom <- postal_codes |>
    filter(.data[[pc_id_col]] == pc_id)
  
  # Build plot
  ggplot() +
    annotation_map_tile(type = "osm", zoom = 15, quiet = TRUE) +
    geom_sf(data = pks_dissolved,
            fill  = "#2166ac", colour = "#2166ac",
            alpha = 0.4, linewidth = 0.3) +
    geom_sf(data = pc_geom,
            fill  = NA, colour = "#d73027",
            linewidth = 0.8, linetype = "dashed") +
    labs(
      title    = pc_id,
      subtitle = paste0(n_parks, " parks  |  ",
                        nrow(pks), " OSM features  →  ",
                        nrow(pks_dissolved), " clusters")
    ) +
    theme_void(base_size = 9) +
    theme(
      plot.title    = element_text(face = "bold", size = 10),
      plot.subtitle = element_text(size  = 8, colour = "grey40"),
      plot.margin   = margin(4, 4, 4, 4)
    )
}

# -----------------------------------------------------------------------------
# Build one plot per top postal code
# -----------------------------------------------------------------------------
plots <- vector("list", N_TOP)

for (i in seq_len(N_TOP)) {
  message("Plotting PC ", i, " of ", N_TOP, ": ", top_pcs$pc_id[i])
  plots[[i]] <- plot_pc_parks(top_pcs[i, ], parks_osm, postal_codes)
}

# Remove any NULLs (postal codes where no OSM parks were found)
plots <- purrr::compact(plots)

# -----------------------------------------------------------------------------
# Combine into a single gridExtra figure
# -----------------------------------------------------------------------------
n_cols <- 3

combined <- arrangeGrob(
  grobs = plots,
  ncol  = n_cols,
  top   = grid::textGrob(
    paste0("Top ", N_TOP, " postal codes by park count — CMA ", CMA,
           "\nBlue polygons: dissolved OSM park clusters  |  Red dashed: postal code boundary"),
    gp = grid::gpar(fontsize = 12, fontface = "bold")
  )
)

# Display
grid::grid.draw(combined)

# Optionally save
# ggsave(paste0("Data/Space_for_Play_Dimension/sanity_check_top_parks_", CMA, ".png"),
#        combined, width = 14, height = 9, dpi = 150)
