# Measured against the live API on 2026-08-02 with `format=csv`, because the docs say
# something else:
#
#   success                 200  text/csv, 15-column header + rows
#   no results              200  *empty body*: zero bytes, no result code at all
#   missing/invalid param   400  JSON `{"epidata": [], "message": …, "result": -1}`
#   unknown endpoint        404  HTML
#

const COVIDCAST_ENDPOINT = "covidcast/"

"""
Header line the `covidcast` endpoint emits in CSV mode.
"""
const COVIDCAST_CSV_HEADER = "geo_value,signal,source,geo_type,time_type,time_value," *
                             "direction,issue,lag,missing_value,missing_stderr," *
                             "missing_sample_size,value,stderr,sample_size"

csv_header(::DelphiCovidcast) = COVIDCAST_CSV_HEADER
endpoint(::DelphiCovidcast) = COVIDCAST_ENDPOINT

"""
    check_result(request, code, message)

Turn Delphi's `result` code into either a return or the right exception.
"""
function check_result(request::AbstractString, code::Union{Int,Nothing}, message::AbstractString)
    code == 1 && return nothing
    code == -2 && throw(NoResultsError(request))
    code == 2 && throw(TruncatedResultsError(request, message))
    throw(EpidataError(request, code, message))
end

"""
    try_json_envelope(body) -> (code, message, data) | nothing

Recognize Delphi's JSON envelope, returning `nothing` for anything that is not one.
"""
function try_json_envelope(body::AbstractString)
    startswith(lstrip(body), '{') || return nothing
    obj = try
        JSON3.read(body)
    catch
        return nothing
    end
    obj isa JSON3.Object || return nothing
    haskey(obj, :result) || return nothing
    code = obj.result isa Integer ? Int(obj.result) : tryparse(Int, string(obj.result))
    msg = haskey(obj, :message) ? string(obj.message) : ""
    data = haskey(obj, :epidata) ? obj.epidata : nothing
    return (code, msg, data)
end

"""
    decode_response(src, resp::EpiResponse) -> Tables.jl source

Turn a raw response into something tabular, or throw the most specific error that fits.
"""
function decode_response(src::AbstractSource, resp::EpiResponse)
    body = body_string(resp)
    stripped = strip(body)

    # An empty body is CSV mode's way of saying "no rows matched": there is no result
    # code to consult, the emptiness *is* the signal. At any other status an empty body
    # is a transport failure with nothing to report.
    if isempty(stripped)
        resp.status == 200 && throw(NoResultsError(resp.request))
        throw(TransportError(resp.request, resp.status, ""))
    end

    # Before the status check, so the server's own message wins over a generic "HTTP 400".
    env = try_json_envelope(stripped)
    if env !== nothing
        code, msg, data = env
        check_result(resp.request, code, msg)
        return data === nothing ? throw(NoResultsError(resp.request)) : data
    end

    if !(200 <= resp.status < 300)
        throw(TransportError(resp.request, resp.status, stripped))
    end

    expected = csv_header(src)
    if !startswith(stripped, expected)
        throw(EpidataError(resp.request, nothing,
            "unrecognized 200 body: not JSON, and does not begin with the expected " *
            "CSV header for this endpoint. First 200 bytes: " * first(stripped, 200)))
    end

    # `geo_value` is forced to String because CSV parsing would otherwise read a county
    # FIPS code such as "06075" as the integer 6075 and lose the leading zero, silently
    # turning it into a different, real county code. `validate = false` lets an endpoint
    # with no `geo_value` column, such as `covidcast_meta`, share this same decoder.
    return CSV.File(resp.body; types = Dict("geo_value" => String), stringtype = String,
                     validate = false)
end

# ---------------------------------------------------------------------------
# Query construction
# ---------------------------------------------------------------------------

"""
    format_time_values(time_type, tv) -> String

Render a time selection into Delphi's packed wire form.

Accepts a packed integer, a `"202620-202629"` range string, a `Date`, 
or a collection of any of those. Converts `Date`s according
to `time_type`, so weekly signals can be queried with real 
dates instead of hand-computed epiweeks.
"""
function format_time_values(time_type::AbstractString, tv)
    tt = lowercase(strip(time_type))
    fmt1(d::Date) = tt == "week" ? (y = epiweek(d); string(y[1], lpad(y[2], 2, '0'))) :
                    Dates.format(d, dateformat"yyyymmdd")
    fmt1(x::Integer) = string(x)
    fmt1(s::AbstractString) = String(strip(s))

    tv isa AbstractString && return String(strip(tv))
    tv isa Integer && return string(tv)
    tv isa Date && return fmt1(tv)
    if tv isa AbstractRange && eltype(tv) <: Date
        return string(fmt1(first(tv)), "-", fmt1(last(tv)))
    end
    if tv isa AbstractVector || tv isa Tuple
        return join((fmt1(x) for x in tv), ",")
    end
    throw(ValidationError("cannot interpret time_values of type $(typeof(tv))"))
end

"""
    covidcast_params(; kwargs...) -> Dict{String,String}

Build and locally validate the query for one `covidcast` request.

`time_type` and `geo_type` are checked here rather than upstream. The anonymous rate limit
is 60 requests/hour, so spending one to be told a parameter was misspelled is a real cost;
these two are checkable for free.
"""
function covidcast_params(;
    data_source::AbstractString,
    signal::AbstractString,
    time_type::AbstractString,
    geo_type::AbstractString,
    time_values,
    geo_value = "*",
    as_of = nothing,
    issues = nothing,
    lag = nothing,
)
    tt = lowercase(strip(time_type))
    tt in ("day", "week") ||
        throw(ValidationError("time_type must be \"day\" or \"week\", got $(repr(time_type))"))
    parse_geo_level(geo_type)  # throws on an unknown geo_type

    params = Dict{String,String}(
        "data_source" => String(data_source),
        "signal" => String(signal),
        "time_type" => tt,
        "geo_type" => lowercase(strip(geo_type)),
        "time_values" => format_time_values(tt, time_values),
        "geo_value" => geo_value isa AbstractString ? String(geo_value) : join(geo_value, ","),
        "format" => "csv",
    )
    as_of === nothing || (params["as_of"] = format_time_values(tt, as_of))
    issues === nothing || (params["issues"] = format_time_values(tt, issues))
    lag === nothing || (params["lag"] = string(lag))
    return params
end

"""
    fetch_covidcast(; data_source, signal, time_type, geo_type, time_values, geo_value="*",
                 transport=HTTPTransport(), kwargs...) -> EpiTable

Fetch one covidcast signal and return it in the standard schema.

```julia
tbl = fetch_covidcast(
    data_source = "nssp",
    signal      = "pct_ed_visits_covid",
    time_type   = "week",
    geo_type    = "state",
    time_values = "202620-202629",
    geo_value   = "ca",
)
```

Throws [`NoResultsError`](@ref) when the query was valid but matched nothing, and
[`TruncatedResultsError`](@ref) when the server capped the result set. See
[`check_result`](@ref) for why that is an error rather than a warning.

!!! warning "V4 stops gaining data on 2026-09-22"
    Delphi adds no new data to the `covidcast` endpoint after 2026-09-22. It keeps serving
    records ingested before then, so this function stays correct for historical work. For
    current data use [`fetch_snapshot`](@ref) or [`fetch_archive`](@ref), and
    `catalog(api = :v5)` to find the new signal names. `doctor-visits` is now
    `claims_outpatient` and `hospital-admissions` is now `claims_inpatient`.
"""
function fetch_covidcast(;
    transport::AbstractTransport = HTTPTransport(),
    as_of = nothing,
    issues = nothing,
    lag = nothing,
    kwargs...,
)
    src = DelphiCovidcast()
    params = covidcast_params(; as_of, issues, lag, kwargs...)
    resp = fetch_raw(transport, endpoint(src), params)
    return standardize(src, decode_response(src, resp))
end

# ---------------------------------------------------------------------------
# fluview
# ---------------------------------------------------------------------------

const FLUVIEW_ENDPOINT = "fluview/"

endpoint(::DelphiFluView) = FLUVIEW_ENDPOINT

"""
    fluview_geo(region) -> (GeoLevel, String)

Infer the geographic level from a fluview region code.

Unlike covidcast, fluview returns no `geo_type` field, so the level is encoded in the region
string itself, so it has to be recovered by shape.
"""
function fluview_geo(region)
    (region === missing || region === nothing) &&
        throw(ValidationError("fluview row has no region; it is required to place an observation"))
    s = lowercase(strip(string(region)))
    lvl = s == "nat"                      ? NATION :
          occursin(r"^hhs([1-9]|10)$", s) ? HHS_REGION :
          occursin(r"^cen[1-9]$", s)      ? CENSUS_DIVISION :
          occursin(r"^[a-z]{2}$", s)      ? STATE :
          throw(ValidationError(
              "unrecognized fluview region $(repr(s)); expected \"nat\", \"hhs1\" to \"hhs10\", " *
              "\"cen1\" to \"cen9\", or a two-letter state abbreviation"))
    return (lvl, normalize_geo_id(lvl, s))
end

"""
    fluview_params(; epiweeks, regions, issues = nothing, lag = nothing) -> Dict{String,String}

Build and locally validate the query for one `fluview` request.

Every region is checked before the request is sent, for the same reason covidcast's
`geo_type` is: the anonymous rate limit is 60 requests/hour and a typo should not cost one.
"""
function fluview_params(; epiweeks, regions, issues = nothing, lag = nothing)
    regs = regions isa AbstractString ? split(regions, ',') : collect(regions)
    isempty(regs) && throw(ValidationError("regions must name at least one region"))
    ids = [fluview_geo(r)[2] for r in regs]

    params = Dict{String,String}(
        "epiweeks" => format_time_values("week", epiweeks),
        "regions" => join(ids, ","),
    )
    issues === nothing || (params["issues"] = format_time_values("week", issues))
    lag === nothing || (params["lag"] = string(lag))
    return params
end

"""
    fetch_fluview(; epiweeks, regions, issues=nothing, lag=nothing,
                  transport=HTTPTransport()) -> EpiTable

Fetch influenza-like illness data and return it in the standard schema.

```julia
tbl = fetch_fluview(epiweeks = Date(2020, 1, 1):Date(2020, 6, 1), regions = ["nat", "hhs1"])
```

Each upstream row carries several measurements, so it becomes several observations
distinguished by `signal`. See [`standardize`](@ref). `fluview` has no `as_of`; use
`issues` or `lag` to select a vintage.

!!! note "fluview is still on the older API"
    `fluview` had not moved to V5 as of 2026-09-08, so this function keeps querying the
    endpoint it always has. Delphi stops adding data to that endpoint on 2026-09-22 as
    well, so it stays correct for historical work. Watch `catalog(api = :v5)` for fluview
    to appear.
"""
function fetch_fluview(;
    transport::AbstractTransport = HTTPTransport(),
    kwargs...,
)
    src = DelphiFluView()
    params = fluview_params(; kwargs...)
    resp = fetch_raw(transport, endpoint(src), params)
    return standardize(src, decode_response(src, resp))
end
