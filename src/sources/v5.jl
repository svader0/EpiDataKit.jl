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

# V5 dropped `lag`. The migration guide says to derive it from report_time - reference_time,
# and this schema counts it in the signal's own units.
function _v5_lag(time_type::Symbol, period_end, issue)
    issue === missing && return missing
    days = Dates.value(issue - period_end)
    return time_type === :week ? div(days, 7) : days
end
