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
"""
empty_catalog() = CatalogTable(CatalogEntry[])

"""
    catalog_params(; source = nothing, signal = nothing, time_type = nothing,
                     geo_type = nothing) -> Dict{String,String}

Build and locally validate the query for one `covidcast_meta` request.

`source` and `time_type` narrow the request upstream. `signal` does too, but only alongside
a `source`, since the wire form is a `source:signal` pair. `geo_type` is validated here and
then applied to the result rather than sent: [`GEO_TYPE_MAP`](@ref) accepts `"hhs_region"`
as an alias for `"hhs"`, and this endpoint answers an alias it does not know with an empty
body rather than an error, so a valid filter would look like missing data.

Both checks happen before any request, for the reason [`covidcast_params`](@ref) gives: the
anonymous limit is 60 requests/hour and a typo should not cost one.
"""
function catalog_params(; source = nothing, signal = nothing,
                          time_type = nothing, geo_type = nothing)
    params = Dict{String,String}("format" => "csv")

    if source !== nothing
        sig = signal === nothing ? "*" : lowercase(strip(string(signal)))
        params["signals"] = string(lowercase(strip(string(source))), ":", sig)
    end

    if time_type !== nothing
        tt = lowercase(strip(string(time_type)))
        tt in ("day", "week") ||
            throw(ValidationError("time_type must be \"day\" or \"week\", got $(repr(time_type))"))
        params["time_types"] = tt
    end

    geo_type === nothing || parse_geo_level(geo_type)  # throws on an unknown geo_type
    return params
end

"""
    catalog_entries(raw) -> CatalogTable

Convert a decoded `covidcast_meta` payload into [`CatalogEntry`](@ref) rows.

`min_time`, `max_time`, and `max_issue` arrive in the row's own `time_type` encoding, so they
go through the same [`period_bounds`](@ref) and [`parse_issue`](@ref) the observation path
uses. `min_time` takes the opening bound and `max_time` the closing one, which for a weekly
row are six days apart.

A row whose `geo_type` this package does not recognize is dropped with a warning rather than
throwing. `hsa_nci` appeared in this endpoint before it appeared in [`GEO_TYPE_MAP`](@ref),
and [`catalog`](@ref) is the function you would call to discover that, so it must not be the
one that dies on it.
"""
function catalog_entries(raw)
    rows = Tables.rows(raw)
    avail = _colnames(raw)
    entries = CatalogEntry[]
    unknown = Set{String}()

    for row in rows
        tt = lowercase(strip(string(_get(row, :time_type, avail))))
        geo = String(strip(string(_get(row, :geo_type, avail))))
        lvl = get(GEO_TYPE_MAP, lowercase(geo), nothing)
        if lvl === nothing
            push!(unknown, geo)
            continue
        end

        push!(entries, CatalogEntry(
            _require_symbol(_get(row, :data_source, avail), :data_source),
            _require_symbol(_get(row, :signal, avail), :signal),
            Symbol(tt),
            lvl,
            period_bounds(tt, _get(row, :min_time, avail))[1],
            period_bounds(tt, _get(row, :max_time, avail))[2],
            coerce_int(_get(row, :num_locations, avail)),
            parse_issue(tt, _get(row, :max_issue, avail)),
            coerce_int(_get(row, :min_lag, avail)),
            coerce_int(_get(row, :max_lag, avail)),
            :fetch_covidcast,
        ))
    end

    isempty(unknown) || @warn(
        "catalog dropped rows carrying a geo_type this version does not know; " *
        "upgrade EpiDataKit or open an issue",
        geo_types = sort!(collect(unknown)))

    return isempty(entries) ? empty_catalog() : CatalogTable(entries)
end

# ---------------------------------------------------------------------------
# fluview
# ---------------------------------------------------------------------------

"""
Geographic levels the `fluview` endpoint serves, matching what [`fluview_geo`](@ref)
accepts: `nat`, `hhs1` to `hhs10`, `cen1` to `cen9`, and state abbreviations.
"""
const FLUVIEW_GEO_LEVELS = (NATION, HHS_REGION, CENSUS_DIVISION, STATE)

"""
    fluview_catalog_entries() -> CatalogTable

The `fluview` half of the catalog, from static data and no request.

`fluview_meta` reports one summary row for the whole table rather than per-signal coverage,
so every extent column here is `missing`. Listing the signals anyway is the point: without
these rows [`catalog`](@ref) reads as though this package cannot fetch ILI at all.
"""
fluview_catalog_entries() = CatalogTable([
    CatalogEntry(:fluview, m, :week, lvl, missing, missing, missing, missing, missing,
                 missing, :fetch_fluview)
    for m in FLUVIEW_MEASURES for lvl in FLUVIEW_GEO_LEVELS
])

_is_fluview_only(source) =
    source !== nothing && lowercase(strip(string(source))) == "fluview"

function _matches(e::CatalogEntry, source, signal, time_type, geo_type)
    source === nothing ||
        Symbol(lowercase(strip(string(source)))) === e.source || return false
    signal === nothing ||
        Symbol(lowercase(strip(string(signal)))) === e.signal || return false
    time_type === nothing ||
        Symbol(lowercase(strip(string(time_type)))) === e.time_type || return false
    geo_type === nothing || parse_geo_level(geo_type) === e.geo_level || return false
    return true
end

function _covidcast_catalog(transport::AbstractTransport, params)
    src = DelphiCovidcastMeta()
    try
        return catalog_entries(decode_response(src,
            fetch_raw(transport, endpoint(src), params)))
    catch e
        # The fluview half may still match, so the caller decides whether nothing matched.
        e isa NoResultsError && return empty_catalog()
        rethrow()
    end
end

# ---------------------------------------------------------------------------
# V5 metadata
# ---------------------------------------------------------------------------

"""
    v5_catalog_entries(json) -> CatalogTable

Convert a V5 `metadata/` reply into [`CatalogEntry`](@ref) rows.

One request describes every source, so this is far cheaper than `covidcast_meta`. What it
does not describe is the time resolution or the per-signal geographic coverage: `geo_types`
is a source-wide list, so the entries are its cross product with `signals`, and `time_type`
is `missing`.

Sources this package cannot fetch are skipped rather than listed, because a catalog entry
is a promise that [`fetch_snapshot`](@ref) accepts it. A source whose tables are still
being rebuilt upstream reports `null` for every field and is skipped the same way.
"""
function v5_catalog_entries(json::AbstractString)
    obj = try
        JSON3.read(json)
    catch e
        e isa InterruptException && rethrow()
        throw(EpidataError(V5_METADATA_ENDPOINT, nothing,
            "metadata/ did not return JSON: " * sprint(showerror, e)))
    end

    entries = CatalogEntry[]
    unknown = Set{String}()

    for (name, meta) in pairs(obj)
        src = Symbol(lowercase(string(name)))
        src in V5_SOURCES || continue
        meta isa JSON3.Object || continue

        sigs = get(meta, :signals, nothing)
        geos = get(meta, :geo_types, nothing)
        (sigs === nothing || geos === nothing) && continue

        ref = get(meta, :reference_time_range, nothing)
        rep = get(meta, :report_time_range, nothing)
        first_period = ref === nothing ? missing : coerce_date(get(ref, :first, missing))
        last_period = ref === nothing ? missing : coerce_date(get(ref, :latest, missing))
        last_issue = rep === nothing ? missing : coerce_date(get(rep, :latest, missing))

        for g in geos
            lvl = get(GEO_TYPE_MAP, lowercase(string(g)), nothing)
            if lvl === nothing
                push!(unknown, string(g))
                continue
            end
            for s in sigs
                push!(entries, CatalogEntry(
                    src, Symbol(string(s)), missing, lvl,
                    first_period, last_period, missing, last_issue, missing, missing,
                    :fetch_snapshot))
            end
        end
    end

    isempty(unknown) || @warn(
        "V5 catalog dropped a geo_type this version does not know; " *
        "upgrade EpiDataKit or open an issue",
        geo_types = sort!(collect(unknown)))

    return isempty(entries) ? empty_catalog() : CatalogTable(entries)
end

function _v5_catalog(transport::AbstractTransport)
    resp = fetch_raw(transport, V5_METADATA_ENDPOINT, Dict{String,String}())
    200 <= resp.status < 300 ||
        throw(TransportError(resp.request, resp.status, first(body_string(resp), 200)))
    return v5_catalog_entries(body_string(resp))
end

"""
    catalog(; source = nothing, signal = nothing, time_type = nothing, geo_type = nothing,
              api = :v4, transport = HTTPTransport()) -> CatalogTable

List the datasets this package can fetch.

```julia
cat = catalog()

unique(cat.source)
filter(e -> e.geo_level == STATE && e.time_type === :week, cat)
```

Each entry names a signal, a time resolution, and a geographic level, plus the extent of the
data and the function that retrieves it. The `covidcast` half comes from the live
`covidcast_meta` endpoint. The `fluview` half is static, because the API publishes no
per-signal coverage for it, so those rows carry `missing` for every extent column. Asking
for `source = "fluview"` makes no request at all.

The `fluview` rows are the signal list, not verified coverage: they say the measure exists
somewhere in the endpoint, not that every level of it returns data. `num_age_2` is a known
example — it is `null` in every recorded reply, so `fetch_fluview` returns zero observations
for it at any geographic level.

One call is one request against a cap of 60/hour for anonymous callers, and the unfiltered
reply is about 400 KB, so bind the result rather than calling this in a loop. `source` and
`time_type` narrow the request itself, and `signal` narrows it too when `source` is given.
`geo_type` filters the result, for the reason [`catalog_params`](@ref) explains.

`api` picks which API to describe. `:v4` (the default) is the `covidcast_meta` endpoint
plus the static fluview rows. `:v5` is the V5 `metadata/` endpoint, one request describing
every source. To see both at once, call each and `vcat` the results.

V5 entries leave `time_type`, `num_locations`, `min_lag` and `max_lag` `missing`, because
`metadata/` does not publish them, and their `fetch_with` is `:fetch_snapshot`. A
`time_type` filter therefore matches no V5 entry and raises `NoResultsError` under
`api = :v5`. Delphi stops adding data to V4 on 2026-09-22, so `api = :v5` is where new
signals appear.

Throws [`NoResultsError`](@ref) when no dataset matches at all. The result is a
[`CatalogTable`](@ref), not an [`EpiTable`](@ref).
"""
function catalog(; source = nothing, signal = nothing, time_type = nothing,
                   geo_type = nothing, api::Symbol = :v4,
                   transport::AbstractTransport = api === :v5 ? v5_transport() : HTTPTransport())
    api in (:v4, :v5) ||
        throw(ValidationError("api must be :v4 or :v5, got $(repr(api))"))

    # "*" is the wire form catalog_params emits for a nil signal, not a signal name.
    signal = (signal === nothing || string(signal) == "*") ? nothing : signal

    all_entries = empty_catalog()
    request = ""

    if api === :v5
        all_entries = _v5_catalog(transport)
        request = V5_METADATA_ENDPOINT
    else
        params = catalog_params(; source, signal, time_type, geo_type)
        fluview_only = _is_fluview_only(source)
        # covidcast_meta has no fluview data_source, so this path never reaches the wire.
        covidcast = fluview_only ? empty_catalog() : _covidcast_catalog(transport, params)
        all_entries = vcat(covidcast, fluview_catalog_entries())
        request = fluview_only ?
            "catalog(source = \"fluview\"): no fluview signal matches the other filters" :
            request_key(COVIDCAST_META_ENDPOINT, params)
    end

    keep = findall(e -> _matches(e, source, signal, time_type, geo_type), all_entries)
    isempty(keep) && throw(NoResultsError(request))
    return all_entries[keep]
end
