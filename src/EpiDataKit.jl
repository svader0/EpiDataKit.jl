"""
    EpiDataKit

Fetch public health surveillance data, standardise it into one tidy schema, and persist it
as Arrow for downstream modelling packages.

```julia
using EpiDataKit

tbl = fetch_signal(
    data_source = "nssp",
    signal      = "pct_ed_visits_covid",
    time_type   = "week",
    geo_type    = "state",
    time_values = "202620-202629",
    geo_value   = "ca",
)

EpiDataKit.save(tbl, "nssp_covid.arrow")
```
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
include("store.jl")

# Schema
export EpiObservation, EpiTable, GeoLevel, MissingCode
export NATION, HHS_REGION, CENSUS_DIVISION, STATE, COUNTY, MSA, HRR, DMA, HSA_NCI
export NOT_MISSING, NOT_APPLICABLE, REGION_EXCEPTION, CENSORED, DELETED, OTHER

# Sources and fetching
export AbstractSource, DelphiCovidcast
export AbstractTransport, HTTPTransport, MockTransport
export fetch_signal, standardize

# Errors
export EpiDataKitError, ValidationError, NoResultsError, TruncatedResultsError,
       EpidataError, TransportError, StoreError

end
