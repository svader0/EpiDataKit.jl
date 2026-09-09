# Measured against the live V5 API on 2026-09-08:
#
#   success             200  text/csv, key header + value columns + rows
#   no rows             200  *header line only*, also for an unknown signal, an unknown
#                            geo_type, and a comma separated signal list
#   bad parameter       422  JSON {"detail": [{"type", "loc", "msg", "input"}]}
#   unknown endpoint    404  HTML

"""
The first six columns of every V5 CSV response, in order. The value columns that follow
vary by source, so this is a prefix check rather than an equality check.
"""
const V5_KEY_HEADER = "signal,report_time,geo_type,geo_value,fill_method,reference_time"

"""
    v5_error_message(body) -> Union{String,Nothing}

Render FastAPI's `detail` array into one line, or return `nothing` for a body that is not
one.
"""
function v5_error_message(body::AbstractString)
    startswith(lstrip(body), '{') || return nothing
    obj = try
        JSON3.read(body)
    catch
        return nothing
    end
    (obj isa JSON3.Object && haskey(obj, :detail)) || return nothing
    detail = obj.detail
    detail isa JSON3.Array || return string(detail)

    parts = String[]
    for d in detail
        loc = haskey(d, :loc) ? join(string.(d.loc), ".") : ""
        msg = haskey(d, :msg) ? string(d.msg) : ""
        push!(parts, isempty(loc) ? msg : string(loc, ": ", msg))
    end
    return join(parts, "; ")
end

"""
    decode_v5(resp::EpiResponse) -> Tables.jl source

Turn a raw V5 response into something tabular, or throw the most specific error that fits.

A body holding only the header line is [`NoResultsError`](@ref): that is how V5 reports an
unknown signal or geo_type, both at status 200.
"""
function decode_v5(resp::EpiResponse)
    body = body_string(resp)
    stripped = strip(lstrip(body, '﻿'))

    isempty(stripped) && throw(TransportError(resp.request, resp.status, ""))

    msg = v5_error_message(stripped)
    msg === nothing || throw(EpidataError(resp.request, resp.status, msg))

    200 <= resp.status < 300 ||
        throw(TransportError(resp.request, resp.status, stripped))

    startswith(stripped, V5_KEY_HEADER) || throw(EpidataError(resp.request, nothing,
        "unrecognized 200 body: it does not begin with the V5 key header " *
        repr(V5_KEY_HEADER) * ". First 200 bytes: " * first(stripped, 200)))

    occursin('\n', stripped) || throw(NoResultsError(resp.request))

    # `geo_value` is forced to String because CSV parsing would otherwise read a county
    # FIPS code such as "06075" as the integer 6075 and lose the leading zero.
    return CSV.File(resp.body; types = Dict("geo_value" => String), stringtype = String,
                    validate = false)
end

"""
    infer_time_type(refs) -> Symbol

Decide whether a V5 payload is daily or weekly from its `reference_time` values.

V5 publishes no `time_type` and `reference_time` is a plain calendar date, so the spacing
is the only signal. It is a reliable one here: V5 does not filter by time, so a response
carries a source's whole history. The smallest positive gap decides, which a run of
missing periods cannot move. Weekly reference times are MMWR week-ending Saturdays.

Returns `:day` when there is not enough to tell, which is the resolution that leaves
`period_start == period_end` and so invents nothing.
"""
function infer_time_type(refs)
    u = sort!(unique(Date[r for r in refs if r !== missing]))
    length(u) < 2 && return :day
    gap = minimum(Dates.value(u[i + 1] - u[i]) for i in 1:(length(u) - 1))
    return gap >= 7 ? :week : :day
end

"""
    standardize(src::DelphiV5, raw; time_type = nothing) -> EpiTable

Convert a decoded V5 payload into the standard schema.

`reference_time` is the closing bound of the observation period, so a weekly row opens six
days earlier and a daily row opens on the same day. Pass `time_type` to override
[`infer_time_type`](@ref); a payload holding one distinct reference time cannot be told
apart on its own.

`lag` is recomputed here rather than read, because V5 dropped the column. It counts the
signal's own time units, matching [`EpiObservation`](@ref).
"""
function standardize(src::DelphiV5, raw; time_type = nothing)
    rows = Tables.rows(raw)
    avail = _colnames(raw)

    refs = [coerce_date(_get(row, :reference_time, avail)) for row in rows]
    if time_type === nothing && length(unique(skipmissing(refs))) < 2
        @warn "one distinct reference_time; assuming a daily signal. Pass time_type = \"week\" if it is weekly" maxlog = 1
    end
    tt = time_type === nothing ? infer_time_type(refs) :
         Symbol(lowercase(strip(string(time_type))))
    tt in (:day, :week) ||
        throw(ValidationError("time_type must be \"day\" or \"week\", got $(repr(time_type))"))
    span = tt === :week ? Day(6) : Day(0)

    c = _columns(rows)
    for (i, row) in enumerate(rows)
        pe = refs[i]
        pe === missing && throw(ValidationError(
            "V5 row has no reference_time; it is required to place an observation"))
        lvl = parse_geo_level(string(_get(row, :geo_type, avail)))
        iss = coerce_date(_get(row, :report_time, avail))
        val = coerce_float(_get(row, :value, avail))

        push!(c.source, src.source)
        push!(c.signal, _require_symbol(_get(row, :signal, avail), :signal))
        push!(c.geo_level, lvl)
        push!(c.geo_id, normalize_geo_id(lvl, _get(row, :geo_value, avail)))
        push!(c.period_start, pe - span)
        push!(c.period_end, pe)
        push!(c.value, val)
        push!(c.stderr, missing)
        push!(c.sample_size, missing)
        push!(c.ci_lower, coerce_float(_get(row, :ci_lower, avail)))
        push!(c.ci_upper, coerce_float(_get(row, :ci_upper, avail)))
        push!(c.issue, iss)
        push!(c.lag, _v5_lag(tt, pe, iss))
        push!(c.fill_method, _require_symbol(_get(row, :fill_method, avail), :fill_method))
        push!(c.missing_code, val === missing ? OTHER : NOT_MISSING)
    end

    return StructArray{EpiObservation}(c)
end

function _v5_lag(time_type::Symbol, period_end, issue)
    issue === missing && return missing
    days = Dates.value(issue - period_end)
    return time_type === :week ? div(days, 7) : days
end

const V5_SNAPSHOT_ENDPOINT = "snapshot/"
const V5_ARCHIVE_ENDPOINT = "archive/"
const V5_METADATA_ENDPOINT = "metadata/"

"""
V5 sources this package fetches. Every one of them has an empty `extra_key_columns`, so
its rows fit [`EpiObservation`](@ref) without loss.
"""
const V5_SOURCES = (:nssp, :nhsn, :claims_outpatient, :claims_inpatient,
                    :nchs_mortality, :sleepcycle, :va_respiratory)

"""
V5 sources this package knows about and refuses, with the reason. Naming them beats a bare
"unknown source", because they are real and a caller who found them on Delphi's site will
otherwise assume the name is misspelled.
"""
const V5_UNSUPPORTED_SOURCES = Dict{Symbol,String}(
    :pophive => "it has the extra key column age_group, which this schema has no field for",
    :nickel_beta => "it has the extra key column age_group, which this schema has no field for",
    :nwss => "it has the extra key columns nwss_source and sample_index, which this schema has no fields for",
    :rvdss => "its tables are still being rebuilt upstream and it publishes no metadata",
    :nssp_no_diff => "it is an internal variant of nssp; use source = \"nssp\"",
)

const V5_RENAMED_SOURCES = Dict{Symbol,String}(
    Symbol("doctor-visits") => "claims_outpatient",
    :doctor_visits => "claims_outpatient",
    Symbol("hospital-admissions") => "claims_inpatient",
    :hospital_admissions => "claims_inpatient",
)

"""
    check_v5_source(source) -> Symbol

Normalize a V5 source name, or throw [`ValidationError`](@ref) explaining what to use
instead.

Checked locally rather than upstream: V5 answers an unknown signal or geo type with an
empty 200 rather than an error, and the anonymous limit is 60 requests/hour.
"""
function check_v5_source(source)
    s = Symbol(lowercase(strip(string(source))))
    s in V5_SOURCES && return s

    haskey(V5_RENAMED_SOURCES, s) && throw(ValidationError(
        "$(repr(String(s))) is a V4 source name; in V5 it is called " *
        "$(repr(V5_RENAMED_SOURCES[s]))"))

    haskey(V5_UNSUPPORTED_SOURCES, s) && throw(ValidationError(
        "source $(repr(String(s))) exists in V5 but EpiDataKit does not support it yet: " *
        V5_UNSUPPORTED_SOURCES[s]))

    s === :fluview && throw(ValidationError(
        "fluview has not moved to V5; use fetch_fluview, which still queries the older API"))

    throw(ValidationError(
        "unknown V5 source $(repr(String(s))); supported: " *
        join(sort!(collect(String.(V5_SOURCES))), ", ")))
end

_v5_date(x::Date) = Dates.format(x, dateformat"yyyy-mm-dd")
_v5_date(x::DateTime) = _v5_date(Date(x))
function _v5_date(s::AbstractString)
    t = strip(s)
    occursin(r"^\d{4}-\d{2}-\d{2}$", t) || throw(ValidationError(
        "V5 dates are YYYY-MM-DD, got $(repr(String(t))). V5 has no epiweek encoding; " *
        "pass a Date, or the calendar date of the week's Saturday"))
    return String(t)
end

"""
    format_report_time_query(x) -> String

Render `/archive/`'s `report_time_query`: an operator followed by an ISO date, with no
space. A bare date means `=`.
"""
function format_report_time_query(x)
    (x isa Date || x isa DateTime) && return string("=", _v5_date(x))
    s = strip(string(x))
    m = match(r"^([<>=]?)\s*(.+)$", s)
    m === nothing && throw(ValidationError("cannot read report_time $(repr(String(s)))"))
    op = isempty(m.captures[1]) ? "=" : m.captures[1]
    return string(op, _v5_date(m.captures[2]))
end

"""
    v5_params(; source, signal, geo_type, snapshot_date = nothing,
                report_time = nothing) -> Dict{String,String}

Build and locally validate one V5 query.

`fill_method`, `geo_values` and `reference_time` are deliberately absent. V5 removed the
last two from the wire, and `fill_method` filtering is broken upstream: the parameter
accepts `fill_ave` while the column holds `ave`, so the filter matches nothing. All three
are applied by [`filter_observations`](@ref) instead.
"""
function v5_params(; source, signal, geo_type, snapshot_date = nothing,
                     report_time = nothing)
    src = check_v5_source(source)

    sig = strip(string(signal))
    isempty(sig) && throw(ValidationError("signal must name a signal"))
    occursin(',', sig) && throw(ValidationError(
        "V5 takes one signal per request, got $(repr(String(sig))). A comma separated " *
        "list returns zero rows with no error upstream. Pass a vector of signals instead; " *
        "fetch_snapshot and fetch_archive send one request each and combine the results"))

    parse_geo_level(geo_type)

    params = Dict{String,String}(
        "source" => String(src),
        "signal" => String(sig),
        "geo_type" => lowercase(strip(string(geo_type))),
        "format" => "csv",
    )
    snapshot_date === nothing || (params["snapshot_date"] = _v5_date(snapshot_date))
    report_time === nothing || (params["report_time_query"] = format_report_time_query(report_time))
    return params
end

const V5_FILL_ALIASES = Dict(:fill_ave => :ave, :fill_zero => :zero, :source => :source,
                             :ave => :ave, :zero => :zero)

_match_geo(::Nothing, _) = true
_match_geo(want::Set{String}, id::AbstractString) = id in want

_geo_set(g::AbstractString) = strip(g) == "*" ? nothing : Set([lowercase(strip(g))])
_geo_set(g::Symbol) = _geo_set(String(g))
_geo_set(g) = Set(lowercase(strip(string(x))) for x in g)

_match_time(::Nothing, _) = true
_match_time(want::AbstractRange{Date}, d::Date) = first(want) <= d <= last(want)
_match_time(want::Set{Date}, d::Date) = d in want

_ref_date(x::Date) = x
_ref_date(x) = Date(_v5_date(string(x)), dateformat"yyyy-mm-dd")

function _time_pred(rt)
    rt isa AbstractString && strip(rt) == "*" && return nothing
    rt isa Date && return Set([rt])
    if rt isa AbstractRange
        eltype(rt) <: Date && return rt
        throw(ValidationError("reference_time range must hold Dates, got $(typeof(rt))"))
    end
    rt isa AbstractString && return Set([_ref_date(rt)])
    (rt isa AbstractVector || rt isa Tuple) && return Set(_ref_date(x) for x in rt)
    throw(ValidationError("cannot interpret reference_time of type $(typeof(rt))"))
end

"""
    filter_observations(tbl; geo_values = "*", reference_time = "*", fill_method = nothing)

Apply the filters V5 no longer applies on the server.

`geo_values` matches `geo_id` case-insensitively. `reference_time` matches `period_end`,
which is what `reference_time` becomes: the closing bound of the period. `fill_method`
accepts either the query spelling (`"fill_ave"`) or the column spelling (`"ave"`).

`"*"` means no filter, matching epidatr's default. An empty result is an empty
[`EpiTable`](@ref), not an error.
"""
function filter_observations(tbl::EpiTable; geo_values = "*", reference_time = "*",
                             fill_method = nothing)
    geo = _geo_set(geo_values)
    time = _time_pred(reference_time)
    fm = fill_method === nothing ? nothing :
         get(V5_FILL_ALIASES, Symbol(lowercase(strip(string(fill_method)))), nothing)
    fill_method === nothing || fm !== nothing || throw(ValidationError(
        "fill_method must be \"source\", \"ave\" or \"zero\" (or their fill_ave and " *
        "fill_zero spellings), got $(repr(string(fill_method)))"))

    keep = findall(o -> _match_geo(geo, o.geo_id) &&
                        _match_time(time, o.period_end) &&
                        (fm === nothing || o.fill_method === fm), tbl)
    return isempty(keep) ? empty_table() : tbl[keep]
end

_signal_list(signal) = signal isa AbstractString || signal isa Symbol ?
                       [string(signal)] : [string(s) for s in signal]

function _fetch_v5_body(transport, endpoint, params, paginate::Bool)
    resp = fetch_raw(transport, endpoint, paginate ?
                     merge(params, Dict("use_pagination" => "true")) : params)
    pages = [resp]
    if paginate
        url = next_link(resp)
        while url !== nothing
            r = fetch_raw(transport, url, Dict{String,String}())
            200 <= r.status < 300 || throw(TransportError(url, r.status, body_string(r)))
            push!(pages, r)
            url = next_link(r)
        end
    end
    length(pages) == 1 && return resp
    joined = join((let s = body_string(p); endswith(s, '\n') ? s : s * '\n' end for p in pages), "")
    return EpiResponse(resp.status, Vector{UInt8}(codeunits(joined)), resp.headers,
                       resp.request)
end

function _fetch_v5(endpoint, transport, signal, time_type, filters; params...)
    signals = _signal_list(signal)
    src = DelphiV5(check_v5_source(params[:source]))
    tables = EpiTable[]

    for sig in signals
        p = v5_params(; signal = sig, params...)
        resp = _fetch_v5_body(transport, endpoint, p, endpoint == V5_ARCHIVE_ENDPOINT)
        raw = try
            decode_v5(resp)
        catch e
            (e isa NoResultsError && length(signals) > 1) || rethrow()
            nothing
        end
        raw === nothing || push!(tables, standardize(src, raw; time_type))
    end

    isempty(tables) && throw(NoResultsError(string(endpoint, " ", signal)))
    combined = length(tables) == 1 ? only(tables) : vcat(tables...)
    out = filter_observations(combined; filters...)
    isempty(out) && throw(NoResultsError(
        "the request returned rows but the geo_values, reference_time or fill_method " *
        "filter matched none of them"))
    return out
end

function _deprecated(new_name::String, old_name::String, old_value, new_value)
    old_value === nothing && return new_value
    @warn "`$old_name` is the V4 name; V5 calls it `$new_name`" maxlog = 1 _id = Symbol(old_name)
    return old_value
end

"""
    fetch_snapshot(; source, signal, geo_type, geo_values = "*", reference_time = "*",
                     fill_method = nothing, snapshot_date = nothing, time_type = nothing,
                     transport = v5_transport()) -> EpiTable

Fetch a V5 signal as it stood on one date, in the standard schema.

```julia
tbl = fetch_snapshot(
    source         = "nssp",
    signal         = "pct_ed_visits_covid",
    geo_type       = "state",
    geo_values     = ["ca", "ny"],
    reference_time = Date(2026, 1, 1):Date(2026, 6, 1),
)
```

`snapshot_date` reconstructs what was known on that date, the way `as_of` did in V4. Omit
it for the latest values.

`geo_values`, `reference_time` and `fill_method` filter the result rather than the request:
V5 returns every location and every reference time for a `(source, signal, geo_type)`, so
one call downloads the signal's whole history. Bind the result instead of calling this in a
loop.

`signal` takes a vector to fetch several at once. That costs one request each, because a
comma separated list returns zero rows upstream.

Throws [`NoResultsError`](@ref) when the server matched nothing, and when it matched rows
that the filters then removed.
"""
function fetch_snapshot(; source, signal, geo_type, geo_values = "*",
                          reference_time = "*", fill_method = nothing,
                          snapshot_date = nothing, time_type = nothing,
                          transport::AbstractTransport = v5_transport(),
                          time_values = nothing, as_of = nothing)
    reference_time = _deprecated("reference_time", "time_values", time_values, reference_time)
    snapshot_date = _deprecated("snapshot_date", "as_of", as_of, snapshot_date)

    return _fetch_v5(V5_SNAPSHOT_ENDPOINT, transport, signal, time_type,
                     (; geo_values, reference_time, fill_method);
                     source, geo_type, snapshot_date)
end

"""
    fetch_archive(; source, signal, geo_type, geo_values = "*", reference_time = "*",
                    fill_method = nothing, report_time = "*", time_type = nothing,
                    transport = v5_transport()) -> EpiTable

Fetch every revision of a V5 signal, in the standard schema.

Where [`fetch_snapshot`](@ref) returns one row per key, this returns one row per change, so
the same period appears once per `issue`. That is what backtesting needs.

`report_time` narrows the request upstream and takes an operator: `Date(2026, 6, 26)` or
`"=2026-06-26"` for one release, `"<2026-06-26"` or `">2026-06-26"` for a range. Omit it,
and the server returns the whole report time history, which the API's own docs warn can run
to gigabytes.

Pagination is on, so the result arrives in pages that this function joins.
"""
function fetch_archive(; source, signal, geo_type, geo_values = "*",
                         reference_time = "*", fill_method = nothing,
                         report_time = "*", time_type = nothing,
                         transport::AbstractTransport = v5_transport(),
                         time_values = nothing, issues = nothing)
    reference_time = _deprecated("reference_time", "time_values", time_values, reference_time)
    report_time = _deprecated("report_time", "issues", issues, report_time)
    rt = report_time isa AbstractString && strip(report_time) == "*" ? nothing : report_time

    return _fetch_v5(V5_ARCHIVE_ENDPOINT, transport, signal, time_type,
                     (; geo_values, reference_time, fill_method);
                     source, geo_type, report_time = rt)
end

"""
    fetch_epidata(; source, signal, geo_type, kwargs...) -> EpiTable

Fetch V5 data, picking the endpoint from the arguments.

Passing `report_time` asks for revision history, so this calls [`fetch_archive`](@ref).
Anything else calls [`fetch_snapshot`](@ref). Passing both is an error, because they
name different endpoints rather than different filters.
"""
function fetch_epidata(; report_time = nothing, snapshot_date = nothing, issues = nothing, kwargs...)
    report_time = _deprecated("report_time", "issues", issues, report_time)
    report_time !== nothing && snapshot_date !== nothing && throw(ValidationError(
        "snapshot_date and report_time select different endpoints: snapshot_date is " *
        "fetch_snapshot, report_time is fetch_archive. Pass one"))
    report_time === nothing && return fetch_snapshot(; snapshot_date, kwargs...)
    return fetch_archive(; report_time, kwargs...)
end
