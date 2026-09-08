# Measured against the live V5 API on 2026-09-08. See
# docs/superpowers/specs/2026-09-08-epidata-v5.md for the full record.
#
#   success             200  text/csv, key header + value columns + rows
#   no rows             200  *header line only*. How an unknown signal, an unknown
#                            geo_type, and a comma separated signal list all answer
#   bad parameter       422  JSON {"detail": [{"type", "loc", "msg", "input"}]}
#   unknown endpoint    404  HTML
#
# There is no `result` code anywhere and no truncation code. Two of the failure modes are
# silent 200s, which is why v5_params validates locally before sending.

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

    # V4 used an empty body for "no rows". V5 always sends the header, so an empty body
    # here means the response was cut short.
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
    coerce_date(x) -> Union{Date,Missing}

Read a V5 date column. `reference_time` arrives as `YYYY-MM-DD`; `report_time` is a
timestamp for some sources and a bare date for others, so the clock part is dropped.
"""
coerce_date(::Missing) = missing
coerce_date(::Nothing) = missing
coerce_date(d::Date) = d
coerce_date(d::DateTime) = Date(d)
function coerce_date(s::AbstractString)
    t = strip(s)
    isempty(t) && return missing
    return Date(first(t, 10), dateformat"yyyy-mm-dd")
end
coerce_date(::Any) = missing

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

# V4 names a caller is likely to still be typing, and where each one went.
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
    v5_params(; source, signal, geo_type, snapshot_date = nothing, report_time = nothing,
                limit = nothing) -> Dict{String,String}

Build and locally validate one V5 query.

`fill_method`, `geo_values` and `reference_time` are deliberately absent. V5 removed the
last two from the wire, and `fill_method` filtering is broken upstream: the parameter
accepts `fill_ave` while the column holds `ave`, so the filter matches nothing. All three
are applied by [`filter_observations`](@ref) instead.
"""
function v5_params(; source, signal, geo_type, snapshot_date = nothing,
                     report_time = nothing, limit = nothing)
    src = check_v5_source(source)

    sig = strip(string(signal))
    isempty(sig) && throw(ValidationError("signal must name a signal"))
    occursin(',', sig) && throw(ValidationError(
        "V5 takes one signal per request, got $(repr(String(sig))). A comma separated " *
        "list returns zero rows with no error upstream. Pass a vector of signals instead; " *
        "fetch_snapshot and fetch_archive send one request each and combine the results"))

    parse_geo_level(geo_type)  # throws on an unknown geo_type

    params = Dict{String,String}(
        "source" => String(src),
        "signal" => String(sig),
        "geo_type" => lowercase(strip(string(geo_type))),
        "format" => "csv",
    )
    snapshot_date === nothing || (params["snapshot_date"] = _v5_date(snapshot_date))
    report_time === nothing || (params["report_time_query"] = format_report_time_query(report_time))
    limit === nothing || (params["limit"] = string(limit))
    return params
end

# The query parameter spells these `fill_ave` and `fill_zero`; the column holds `ave` and
# `zero`. Accept either spelling from a caller.
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
