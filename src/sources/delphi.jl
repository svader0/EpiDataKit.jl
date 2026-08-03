# The Delphi Epidata `covidcast` endpoint.
#
# The response contract here is not the one you would guess, and it is not the one the
# docs describe in prose. Measured against the live API on 2026-08-02, requesting
# `format=csv`:
#
#   success                 200  text/csv, 15-column header + rows
#   no results              200  *empty body* — zero bytes, no result code at all
#   missing/invalid param   400  JSON `{"epidata": [], "message": …, "result": -1}`
#                                — JSON even though format=csv was requested
#   unknown endpoint        404  HTML
#
# For contrast, the same no-results query *without* `format=csv` returns 200 with
# `result: -2`. So the widely repeated advice "Delphi signals errors with HTTP 200, trust
# `result` and ignore the status" is true only in JSON mode. In CSV mode an empty body is
# the no-results signal and genuine validation failures do use a correct 4xx.
#
# `decode_response` is written to that table and is the only place any of it is known.

const COVIDCAST_ENDPOINT = "covidcast/"

"""
Exact header line the `covidcast` endpoint emits in CSV mode, captured live.

Checked as a prefix so a response that is neither JSON nor this endpoint's CSV is caught
rather than fed to the parser to fail in some less legible way.
"""
const COVIDCAST_CSV_HEADER = "geo_value,signal,source,geo_type,time_type,time_value," *
                             "direction,issue,lag,missing_value,missing_stderr," *
                             "missing_sample_size,value,stderr,sample_size"

csv_header(::DelphiCovidcast) = COVIDCAST_CSV_HEADER
endpoint(::DelphiCovidcast) = COVIDCAST_ENDPOINT

"""
    check_result(request, code, message)

Turn Delphi's `result` code into either a return or the right exception.

Code `2` — "too many results, data truncated" — is the one that matters most. It arrives
looking exactly like success, so treating it as success means silently analysing a prefix
of the data. It gets its own exception type so a chunked fetch layer can catch it,
subdivide the time window, and retry.
"""
function check_result(request::AbstractString, code::Union{Int,Nothing}, message::AbstractString)
    code == 1 && return nothing
    code == -2 && throw(NoResultsError(request))
    code == 2 && throw(TruncatedResultsError(request, message))
    throw(EpidataError(request, code, message))
end

"""
    try_json_envelope(body) -> (code, message, data) | nothing

Recognise Delphi's JSON envelope, returning `nothing` for anything that is not one.

Deliberately tolerant: it is called on bodies that are usually CSV and occasionally an
HTML error page, so a parse failure is an expected outcome and not worth an exception.
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

Every way this endpoint can fail funnels through here, so error handling lives in one
place instead of being scattered across the fetch and parse paths.
"""
function decode_response(src::AbstractSource, resp::EpiResponse)
    body = body_string(resp)
    stripped = strip(body)

    # An empty body is CSV mode's way of saying "no rows matched" — there is no result
    # code to consult, the emptiness *is* the signal. At any other status an empty body
    # is a transport failure with nothing to report.
    if isempty(stripped)
        resp.status == 200 && throw(NoResultsError(resp.request))
        throw(TransportError(resp.request, resp.status, ""))
    end

    # Delphi's own error format, which can arrive at 200 (JSON mode) or 400 (CSV mode).
    # Checked before the status so the server's specific message wins over a generic
    # "HTTP 400" that says nothing about what was actually wrong.
    env = try_json_envelope(stripped)
    if env !== nothing
        code, msg, data = env
        check_result(resp.request, code, msg)
        # Only reached on result == 1: a JSON-mode success. Not what this package
        # requests, but decoding it costs nothing and keeps the function total.
        return data === nothing ? throw(NoResultsError(resp.request)) : data
    end

    # Not JSON, and not a success: an HTML 404, a proxy page, a gateway error.
    if !(200 <= resp.status < 300)
        throw(TransportError(resp.request, resp.status, stripped))
    end

    expected = csv_header(src)
    if !startswith(stripped, expected)
        throw(EpidataError(resp.request, nothing,
            "unrecognised 200 body: not JSON, and does not begin with the expected " *
            "CSV header for this endpoint. First 200 bytes: " * first(stripped, 200)))
    end

    # `geo_value` is forced to String because CSV parsing would otherwise read a county
    # FIPS code such as "06075" as the integer 6075 and lose the leading zero, silently
    # turning it into a different, real county code.
    return CSV.File(resp.body; types = Dict("geo_value" => String), stringtype = String)
end

# ---------------------------------------------------------------------------
# Query construction
# ---------------------------------------------------------------------------

"""
    format_time_values(time_type, tv) -> String

Render a time selection into Delphi's packed wire form.

Accepts what a caller would naturally reach for — a packed integer, a `"202620-202629"`
range string, a `Date`, or a collection of any of those — and converts `Date`s according
to `time_type`, so weekly signals can be queried with real dates instead of hand-computed
epiweeks.
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
    fetch_signal(; data_source, signal, time_type, geo_type, time_values, geo_value="*",
                 transport=HTTPTransport(), kwargs...) -> EpiTable

Fetch one covidcast signal and return it in the standard schema.

```julia
tbl = fetch_signal(
    data_source = "nssp",
    signal      = "pct_ed_visits_covid",
    time_type   = "week",
    geo_type    = "state",
    time_values = "202620-202629",
    geo_value   = "ca",
)
```

Throws [`NoResultsError`](@ref) when the query was valid but matched nothing, and
[`TruncatedResultsError`](@ref) when the server capped the result set — see
[`check_result`](@ref) for why that is an error rather than a warning.
"""
function fetch_signal(;
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
