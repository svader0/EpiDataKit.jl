# V5 cast-API, served from delphi.cmu.edu. See test/fixtures/README.md for the recorded
# contract.

const V5_SNAPSHOT_ENDPOINT = "v5/snapshot/"
const V5_ARCHIVE_ENDPOINT = "v5/archive/"
const V5_METADATA_ENDPOINT = "v5/metadata/"
const V5_REFERENCE_TIMES_ENDPOINT = "v5/metadata/reference_times/"

"""
Start of the CSV header every V5 data response shares; `age_group` and the CI columns
may follow, and `value` is last.
"""
const V5_CSV_HEADER_PREFIX = "signal,report_time,geo_type,geo_value,fill_method,reference_time"

csv_header(::DelphiV5) = V5_CSV_HEADER_PREFIX

"""
    format_v5_times(x; bare_dates = true) -> String | nothing

Render a time selection for `reference_times` or `report_time_query`. Expressions such as
`">=2026-01-01"` and `"a:b"` pass through; collections join with `,`, which the API ORs.

A lone `Date` means "that day" for `reference_times`, but a `report_time` is a timestamp,
so a bare date would silently select only midnight UTC. `bare_dates = false` rejects it.
"""
function format_v5_times(x; bare_dates::Bool = true)
    (x === nothing || x == "*") && return nothing
    function one(d::Date)
        bare_dates || throw(ValidationError(
            "a bare date is ambiguous for report_time; use \"<=$d\" or " *
            "fetch_snapshot(snapshot_date = $d)"))
        return "$d:$d"
    end
    function one(r::AbstractRange{Date})
        isempty(r) && throw(ValidationError("empty date range $r"))
        return "$(first(r)):$(last(r))"
    end
    function one(s::AbstractString)
        s = strip(s)
        (startswith(s, r"[<>=]") || occursin(':', s)) && return String(s)
        d = tryparse(Date, s)
        d === nothing && throw(ValidationError("cannot interpret time selection $(repr(s))"))
        return one(d)
    end
    one(v::Union{AbstractVector,Tuple}) = join((something(format_v5_times(e; bare_dates), "*")
                                                for e in v), ",")
    one(other) = throw(ValidationError("cannot interpret time selection of type $(typeof(other))"))
    return one(x)
end

const _V5_SNAPSHOT_DATE = r"^\d{4}-\d{2}-\d{2}$|^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?Z$"

function _v5_name(x, what)
    s = lowercase(strip(string(x)))
    isempty(s) && throw(ValidationError("$what must not be empty"))
    return s
end

"""
    v5_params(; source, signal, geo_type, ...) -> Dict{String,String}

Build and locally validate the query for one V5 request. Like [`covidcast_params`](@ref),
it catches typos before spending a request.
"""
function v5_params(;
    source, signal, geo_type,
    geo_values = nothing,
    reference_times = nothing,
    fill_method = nothing,
    age_group = nothing,
    snapshot_date = nothing,
    report_time = nothing,
)
    snapshot_date !== nothing && report_time !== nothing && throw(ValidationError(
        "snapshot_date and report_time are mutually exclusive"))
    level = parse_geo_level(geo_type isa GeoLevel ? GEO_TYPE_NAMES[geo_type] : geo_type)
    params = Dict{String,String}(
        "source" => _v5_name(source, "source"),
        "signal" => _v5_name(signal, "signal"),
        "geo_type" => GEO_TYPE_NAMES[level],
        "format" => "csv",
    )
    if geo_values !== nothing && geo_values != "*"
        vals = geo_values isa AbstractString ? split(geo_values, ',') : collect(geo_values)
        isempty(vals) && throw(ValidationError("geo_values is empty"))
        params["geo_value"] = join((normalize_geo_id(level, v) for v in vals), ",")
    end
    rt = format_v5_times(reference_times)
    rt === nothing || (params["reference_times"] = rt)
    fill_method === nothing || (params["fill_method"] = _v5_name(fill_method, "fill_method"))
    if age_group !== nothing
        ags = age_group isa AbstractString ? [age_group] : collect(age_group)
        params["extra_keys"] = join(("age_group:$v" for v in ags), ",")
    end
    if snapshot_date isa Date
        params["snapshot_date"] = string(snapshot_date)
    elseif snapshot_date !== nothing
        s = strip(string(snapshot_date))
        occursin(_V5_SNAPSHOT_DATE, s) || throw(ValidationError(
            "snapshot_date must be a Date, yyyy-mm-dd or yyyy-mm-ddTHH:MM[:SS]Z, got $(repr(s))"))
        params["snapshot_date"] = s
    end
    rtq = format_v5_times(report_time; bare_dates = false)
    rtq === nothing || (params["report_time_query"] = rtq)
    return params
end

"""
    decode_v5_json(resp) -> JSON3.Object

Decode a V5 metadata response, which is plain JSON rather than CSV. Errors surface as
they do in [`decode_response`](@ref).
"""
function decode_v5_json(resp::EpiResponse)
    body = strip(body_string(resp))
    env = try_json_envelope(body)
    env === nothing || check_result(resp.request, env[1], env[2])
    200 <= resp.status < 300 || throw(TransportError(resp.request, resp.status, body))
    obj = try
        JSON3.read(body)
    catch
        nothing
    end
    obj isa JSON3.Object || throw(EpidataError(resp.request, nothing,
        "expected a JSON object from V5 metadata, got: " * first(body, 200)))
    return obj
end

"""
    v5_reference_times(transport, source, signal) -> Vector{Date}

Every reference date the signal has ever had; the only way to tell weekly from daily when
a result holds a single date.
"""
function v5_reference_times(transport, source, signal)
    resp = fetch_raw(transport, V5_REFERENCE_TIMES_ENDPOINT,
                     Dict("source" => source, "signal" => signal))
    return Date[Date(s) for s in decode_v5_json(resp).reference_times]
end

# V5 answers a misspelled signal or geo_type exactly like an empty window, so the metadata
# is the only way to tell the two apart.
function _explain_empty(transport, params)
    meta = try
        decode_v5_json(fetch_raw(transport, V5_METADATA_ENDPOINT,
                                 Dict("source" => params["source"])))
    catch
        return nothing
    end
    entry = get(meta, Symbol(params["source"]), nothing)
    entry === nothing && return nothing
    signals = String[string(s) for s in get(entry, :signals, ())]
    geos = String[string(g) for g in get(entry, :geo_types, ())]
    if !isempty(signals) && params["signal"] ∉ signals
        throw(ValidationError("$(params["source"]) has no signal $(repr(params["signal"])); " *
                              "available: " * join(sort(signals), ", ")))
    end
    if !isempty(geos) && params["geo_type"] ∉ geos
        throw(ValidationError("$(params["source"]) has no geo_type $(repr(params["geo_type"])); " *
                              "available: " * join(sort(geos), ", ")))
    end
    return nothing
end

function _fetch_v5(transport, endpoint, params)
    src = DelphiV5(Symbol(params["source"]))
    raw = try
        decode_response(src, fetch_raw(transport, endpoint, params))
    catch e
        e isa NoResultsError && _explain_empty(transport, params)
        rethrow()
    end
    tt = v5_time_type(raw)
    # One reference date cannot tell a week from a day; the signal's full date list can.
    if tt === nothing
        # ponytail: a signal with a single reference date ever reads as daily
        tt = something(v5_time_type(v5_reference_times(transport, params["source"], params["signal"])), :day)
    end
    return standardize(src, raw; time_type = tt)
end

"""
    fetch_snapshot(; source, signal, geo_type, geo_values = nothing, reference_times = nothing,
                   fill_method = nothing, age_group = nothing, snapshot_date = nothing,
                   transport = HTTPTransport()) -> EpiTable

Fetch the latest (or, with `snapshot_date`, the as-of) value of a signal from the V5
cast-API.

```julia
tbl = fetch_snapshot(source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state",
                     geo_values = ["ca", "ny"], reference_times = Date(2026, 1, 1):Date(2026, 1, 31))
```

`geo_values` and `reference_times` filter server-side. `lag` is computed client-side from
`issue` and `period_start`, in the signal's own units, and `stderr` and `sample_size` are
`missing` because V5 does not report them. When `fill_method` is omitted the server picks
its own default, which varies by source.

V5 reports neither time resolution nor typos, so two cases cost one extra request: an empty
result (a metadata lookup, to turn a misspelled signal or `geo_type` into a
[`ValidationError`](@ref) listing the real ones; otherwise [`NoResultsError`](@ref) stands)
and a result with a single reference date (to tell a weekly signal from a daily one).
"""
function fetch_snapshot(; transport::AbstractTransport = HTTPTransport(), kwargs...)
    return _fetch_v5(transport, V5_SNAPSHOT_ENDPOINT, v5_params(; kwargs...))
end

"""
    fetch_archive(; source, signal, geo_type, geo_values = nothing, reference_times = nothing,
                  fill_method = nothing, age_group = nothing, report_time = nothing,
                  transport = HTTPTransport()) -> EpiTable

Fetch every revision of a signal, one row per `(period, issue)`. `report_time` selects
issues with an expression such as `">=2026-10-01"` or a date range; a bare `Date` is
rejected because a report time is a timestamp. The other keywords, and the extra-request
cases, are as in [`fetch_snapshot`](@ref).
"""
function fetch_archive(; transport::AbstractTransport = HTTPTransport(), kwargs...)
    return _fetch_v5(transport, V5_ARCHIVE_ENDPOINT, v5_params(; kwargs...))
end
