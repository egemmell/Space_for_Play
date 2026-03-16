# Space for Play Indicators

R scripts for calculating formal play space indicators for the 35 largest Canadian Census Metropolitan Areas (CMAs). Park accessibility is measured as the number of distinct parks within a 500m buffer of each postal code centroid, combining data from CanMap Content Suite and OpenStreetMap.

---

## Overview

The Space for Play domain includes both formal (parks, playgrounds) and informal (open space) play indicators. This repository covers the **formal play space indicator** used in the PlayScore playability index.

The workflow runs in three stages:

1. **Filter CanMap parks** — national park polygons are filtered to relevant classification types and cropped to each CMA study area (+1000m boundary buffer)
2. **Download OSM parks** — park polygons are downloaded from OpenStreetMap for each CMA using the `leisure` key (`park`, `playground`, `dog_park`, `common`), filtered to features ≥ 100m²
3. **Count parks per postal code** — OSM sub-features belonging to the same park are dissolved into distinct clusters, combined with CanMap parks, and the number of distinct parks within a 500m buffer of each postal code centroid (from CanMap Content Suite 2020v.3) is counted.

---

## Repository Structure

```
space-for-play-indicators/
├── README.md
├── .gitignore
├── R/
│   ├── space_for_play_indicators.R   # main analysis script (Sections 1–3)
│   └── sanity_check_top_parks.R      # visualisation script for QA
└── Data/                             # not tracked by git — see Data Sources below
    ├── CMAcodes                      # R object: vector of Census Metropolitan Area codes
    ├── CanMapPC/                     # postal code shapefiles per CMA
    │   └── CMAPC<code>.shp
    └── Space_for_Play_Dimension/
        ├── CANMAP parks/             # CanMap park shapefiles (input + outputs)
        │   ├── ParksSportsFieldRegion.shp   # national CanMap parks (input)
        │   ├── bigpark.shp                  # filtered national parks (output)
        │   └── cmapks<code>.shp             # CMA-level CanMap parks (output)
        ├── OSMparks/                 # OSM park shapefiles per CMA (output)
        │   └── osmpk<date>_<code>.shp
        └── all_parks<code>.csv       # final park counts per postal code (output)
```

---

## Output Format

Each `all_parks<CMA>.csv` file contains one row per postal code with the following columns:

| Column | Description |
|---|---|
| `pc_id` | Postal code identifier |
| `parks` | Number of distinct parks within 500m of the postal code centroid |
| `osm_cluster_id` | Semicolon-separated IDs of dissolved OSM park clusters intersecting the buffer |
| `osm_ids` | Semicolon-separated original OSM feature IDs within those clusters |
| `cm_id` | Semicolon-separated CanMap park IDs for overlapping CanMap features |

---

## Data Sources

### CanMap Content Suite 2020 v.3
Available from DMTI Spatial via institutional licence. The following files are required:

- `Data/Space_for_Play_Dimension/CANMAP parks/ParksSportsFieldRegion.shp` — national park polygons
- `Data/CanMapPC/CMAPC<code>.shp` — postal code shapefiles for each CMA

CanMap park features are filtered to the following `CLASS` values:

```
PARK/SPORTS FIELD, RECREATION, DAY USE, BOTANICAL GARDEN,
NATURAL ENVIRONMENT, PICNIC SITE, NATURE RESERVE, RECREATION AREA,
PROVINCIAL PARK, NATURAL AREA, PARK RESERVE
```

### OpenStreetMap
Downloaded automatically by `space_for_play_indicators.R` via the [`osmdata`](https://docs.ropensci.org/osmdata/) package. No manual download required. Features are queried with:
- **Key:** `leisure`
- **Values:** `park`, `playground`, `dog_park`, `common`
- **Minimum area:** 100m² (filters out incorrectly tagged sub-features)

### CMA Codes
`Data/CMAcodes` is an R object (`.RData` file) containing a vector of CMA codes defining the study areas. This file should be provided separately.

---

## Methods Notes

### CRS conventions
- All spatial operations use **EPSG:3347** (Statistics Canada Lambert, metres)
- **EPSG:4326** (WGS84) is used only where required: OSM Overpass API queries and `st_crop()` operations

### Bounding box buffer
Each CMA bounding box is extended by **1000m** before cropping CanMap parks and querying OSM. This ensures parks near CMA boundaries are captured for postal codes close to the edge of the study area. Buffering is performed in EPSG:3347 for accurate metre-based distances before converting back to WGS84.

### OSM dissolve strategy
OSM frequently maps large parks as many individual overlapping features — sports fields, playgrounds, garden beds etc. — each with a unique `osm_id`. Without dissolving, these inflate the park count per postal code. The script dissolves all touching/overlapping OSM polygons using `st_union()`, then splits the result into spatially disconnected clusters using `st_cast("POLYGON")`. Each cluster is counted as one distinct park. The original `osm_id` values for all features within each cluster are retained in the output CSV for full traceability.

### Deduplication
After spatially joining OSM clusters with CanMap parks, `distinct()` ensures that a single park overlapping multiple CanMap polygons is counted only once per postal code buffer.

---

## Dependencies

```r
install.packages(c("sf", "tidyverse", "osmdata", "lwgeom",
                   "ggspatial", "prettymapr", "gridExtra"))
```

| Package | Version tested | Purpose |
|---|---|---|
| `sf` | ≥ 1.0 | spatial data handling |
| `tidyverse` | ≥ 2.0 | data manipulation |
| `osmdata` | ≥ 0.2 | OSM Overpass API queries |
| `lwgeom` | ≥ 0.2 | extended geometry operations |
| `ggspatial` | ≥ 1.1 | OSM basemap tiles (QA plots) |
| `prettymapr` | ≥ 0.2 | dependency of ggspatial |
| `gridExtra` | ≥ 2.3 | multi-panel plot layout (QA plots) |

---

## Usage

1. Clone this repository and set up the `Data/` folder structure as described above
2. Place CanMap shapefiles in the correct locations
3. Open `R/space_for_play_indicators.R` and run each section in order:
   - **Section 1** only needs to be run once (or when CanMap data changes)
   - **Section 2** only needs to be re-run if OSM data needs refreshing
   - **Section 3** can be re-run independently if analysis parameters change
4. To QA results, run `R/sanity_check_top_parks.R` — set the `CMA` variable at the top to the desired CMA code

---

## Notes on OSM Data Currency

OSM data is downloaded live from the Overpass API at run time. The `OSM_FILE_PREFIX` constant in `space_for_play_indicators.R` includes a date stamp (e.g. `osmpk03132026_`) to track when data was downloaded. If re-downloading OSM data at a later date, update this constant to reflect the new download date so outputs from different vintages are not mixed.