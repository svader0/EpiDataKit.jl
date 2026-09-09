"""
    EpiDataKit

Fetch public health surveillance data, standardize it into one tidy schema, and persist it
as Arrow for downstream modeling packages.

```julia
using EpiDataKit

tbl = fetch_snapshot(
    source         = "nssp",
    signal         = "pct_ed_visits_covid",
    geo_type       = "state",
    geo_values     = "ca",
    reference_time = Date(2026, 1, 1):Date(2026, 6, 1),
)

flu = fetch_fluview(epiweeks = "202020-202029", regions = ["nat"])

EpiDataKit.save(vcat(tbl, flu), "surveillance.arrow")
EpiDataKit.scan("surveillance.arrow")
```

Every endpoint produces the same [`EpiObservation`](@ref) schema, so results combine
without special-casing. [`fetch_snapshot`](@ref) and [`fetch_archive`](@ref) read the V5
API; [`fetch_covidcast`](@ref) and [`fetch_fluview`](@ref) read the older one, which stops
gaining data on 2026-09-22. [`EpiDataKit.load`](@ref) reads a file into mutable vectors;
[`EpiDataKit.scan`](@ref) memory-maps it read-only for a fraction of the cost.
"""
module EpiDataKit

using Dates
using Base64: base64encode

using Arrow
using ArrowTypes
using CSV
using HTTP
using JSON3
using StructArrays
using Tables

include("types.jl")
include("arrowtypes.jl")
include("epiweek.jl")
include("geo.jl")
include("transport.jl")
include("standardize.jl")
include("sources/delphi.jl")
include("sources/v5.jl")
include("catalog.jl")
include("store.jl")

# Schema
export EpiObservation, EpiTable, GeoLevel, MissingCode
export NATION, HHS_REGION, CENSUS_DIVISION, STATE, COUNTY, MSA, HRR, DMA, HSA_NCI
export CENSUS_REGION, SEWERSHED, VA_FACILITY
export NOT_MISSING, NOT_APPLICABLE, REGION_EXCEPTION, CENSORED, DELETED, OTHER

# Sources and fetching
export AbstractSource, DelphiCovidcast, DelphiFluView, DelphiCovidcastMeta, DelphiV5
export AbstractTransport, HTTPTransport, MockTransport, v5_transport
export fetch_covidcast, fetch_fluview, fetch_snapshot, fetch_archive, fetch_epidata,
       standardize

# Catalog
export CatalogEntry, CatalogTable, catalog

# Errors
export EpiDataKitError, ValidationError, NoResultsError, TruncatedResultsError,
       EpidataError, TransportError, StoreError

end
