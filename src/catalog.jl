# Measured against the live `covidcast_meta` endpoint on 2026-08-21 with `format=csv`:
#
#   success            200  text/csv, 15-column header + rows (2970 rows, ~415 KB unfiltered)
#   no results         200  *empty body*, exactly as the covidcast endpoint does it
#   bad parameter      200  *empty body* as well: this endpoint does not validate
#                           `geo_types` or `time_types`, it just matches nothing
#
# `signals` takes `source:signal` pairs and accepts the wildcard `source:*`.

const COVIDCAST_META_ENDPOINT = "covidcast_meta/"

"""
Header line the `covidcast_meta` endpoint emits in CSV mode.

Four of these columns are value statistics a catalog has no use for. They are still in the
constant because [`decode_response`](@ref) gates a 200 body on the header matching exactly,
and the request asks for every field.
"""
const COVIDCAST_META_CSV_HEADER =
    "data_source,signal,time_type,geo_type,min_time,max_time,num_locations," *
    "min_value,max_value,mean_value,stdev_value,last_update,max_issue,min_lag,max_lag"

csv_header(::DelphiCovidcastMeta) = COVIDCAST_META_CSV_HEADER
endpoint(::DelphiCovidcastMeta) = COVIDCAST_META_ENDPOINT

"""
    CatalogTable(entries::AbstractVector{CatalogEntry}) -> CatalogTable

Build a [`CatalogTable`](@ref) from loose entries, the way
[`EpiTable`](@ref) is built from loose observations.
"""
CatalogTable(entries::AbstractVector{CatalogEntry}) = StructArray(entries)

"""
    empty_catalog() -> CatalogTable

A zero-row catalog with the right column types, for the half of a query that matched
nothing.

Spelled out rather than `StructArray(CatalogEntry[])` because the two halves of
[`catalog`](@ref) are combined with `vcat`, which needs their column types to agree.
"""
empty_catalog() = StructArray{CatalogEntry}((
    source = Symbol[], signal = Symbol[], time_type = Symbol[], geo_level = GeoLevel[],
    first_period = Union{Date,Missing}[], last_period = Union{Date,Missing}[],
    num_locations = Union{Int,Missing}[], last_issue = Union{Date,Missing}[],
    min_lag = Union{Int,Missing}[], max_lag = Union{Int,Missing}[],
    fetch_with = Symbol[],
))
