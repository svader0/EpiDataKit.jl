"""
    EpiDataKit

Fetch public health surveillance data, standardize it into one tidy schema, and persist it
as Arrow for downstream modeling packages.

```julia
using EpiDataKit

tbl = fetch_covidcast(
    data_source = "nssp",
    signal      = "pct_ed_visits_covid",
    time_type   = "week",
    geo_type    = "state",
    time_values = "202620-202629",
    geo_value   = "ca",
)

flu = fetch_fluview(epiweeks = "202020-202029", regions = ["nat"])

EpiDataKit.save(vcat(tbl, flu), "surveillance.arrow")
EpiDataKit.scan("surveillance.arrow")
```

Both endpoints produce the same [`EpiObservation`](@ref) schema, so results combine without
special-casing. [`EpiDataKit.load`](@ref) reads a file into mutable vectors;
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
include("catalog.jl")
include("store.jl")

# Schema
export EpiObservation, EpiTable, GeoLevel, MissingCode
export NATION, HHS_REGION, CENSUS_DIVISION, STATE, COUNTY, MSA, HRR, DMA, HSA_NCI
export NOT_MISSING, NOT_APPLICABLE, REGION_EXCEPTION, CENSORED, DELETED, OTHER

# Sources and fetching
export AbstractSource, DelphiCovidcast, DelphiFluView, DelphiCovidcastMeta
export AbstractTransport, HTTPTransport, MockTransport
export fetch_covidcast, fetch_fluview, standardize

# Catalog
export CatalogEntry, CatalogTable, catalog

# Errors
export EpiDataKitError, ValidationError, NoResultsError, TruncatedResultsError,
       EpidataError, TransportError, StoreError

end
