
"""
    coerce_float(x) -> Union{Float64,Missing}

Read a measurement that may arrive as a number, as a string, or not at all.
"""
coerce_float(::Missing) = missing
coerce_float(::Nothing) = missing
coerce_float(x::Real) = isnan(x) ? missing : Float64(x)
function coerce_float(s::AbstractString)
    t = strip(s)
    (isempty(t) || uppercase(t) in ("NA", "NAN", "NULL", "NONE")) && return missing
    v = tryparse(Float64, t)
    return v === nothing || isnan(v) ? missing : v
end
coerce_float(::Any) = missing

"""
    coerce_missing_code(x) -> MissingCode

Map Delphi's integer missingness code onto [`MissingCode`](@ref).

An absent code means the value is present. That is the overwhelmingly common case, and
the endpoint omits the column entirely for some sources. An unrecognized code maps to
`OTHER` rather than throwing: a new code added upstream should not break ingestion of
rows that are otherwise fine.
"""
coerce_missing_code(::Missing) = NOT_MISSING
coerce_missing_code(::Nothing) = NOT_MISSING
function coerce_missing_code(x::Integer)
    lo, hi = Int(typemin(MissingCode)), Int(typemax(MissingCode))
    return (lo <= x <= hi) ? MissingCode(Int8(x)) : OTHER
end
function coerce_missing_code(s::AbstractString)
    t = strip(s)
    isempty(t) && return NOT_MISSING
    v = tryparse(Int, t)
    return v === nothing ? OTHER : coerce_missing_code(v)
end
coerce_missing_code(::Any) = OTHER

"""
    coerce_int(x) -> Union{Int,Missing}

Read a whole-number field that may arrive as a number, as a string, or not at all.

A reported lag is whole periods by definition, so the float path is a rounding rather than a
truncation of anything meaningful.
"""
coerce_int(x) = (v = coerce_float(x); v === missing ? missing : round(Int, v))

# Column access tolerating an absent field, since these APIs omit keys rather than sending
# nulls. A source declaring a `Tables.schema` guarantees every row has every column, so the
# name set is computed once; schemaless JSON guarantees nothing, and taking the first row's
# keys as the answer would both drop values later rows carry and still throw on a row that
# omits one, so those are checked per row.
_colnames(raw) = (sch = Tables.schema(raw); sch === nothing ? nothing : Set{Symbol}(sch.names))

@inline function _get(row, name::Symbol, avail::Union{Set{Symbol},Nothing})
    names = avail === nothing ? Tables.columnnames(row) : avail
    name in names || return missing
    v = Tables.getcolumn(row, name)
    return v === nothing ? missing : v
end

# `source` and `signal` identify the measurement and are non-nullable in the schema.
# Passing an absent value through `string` would coin the plausible-looking `:missing`,
# so an absent one is an error rather than a value.
@inline function _require_symbol(v, field::Symbol)
    (v === missing || v === nothing) &&
        throw(ValidationError("row has no $field; it is required to identify an observation"))
    s = strip(string(v))
    isempty(s) && throw(ValidationError("row has an empty $field"))
    return Symbol(s)
end

# Empty schema columns, preallocated. A plain vector of rows reports `HasShape` rather than
# `HasLength`, and treating that as unknown turned every `sizehint!` into a no-op.
function _columns(rows, per_row::Int = 1)
    n = Base.IteratorSize(typeof(rows)) isa Union{Base.HasLength,Base.HasShape} ?
        length(rows) * per_row : 0
    cols = (source = Symbol[], signal = Symbol[], geo_level = GeoLevel[], geo_id = String[],
            period_start = Date[], period_end = Date[],
            value = Union{Float64,Missing}[], stderr = Union{Float64,Missing}[],
            sample_size = Union{Float64,Missing}[], issue = Union{Date,Missing}[],
            lag = Union{Int,Missing}[], missing_code = MissingCode[])
    foreach(c -> sizehint!(c, n), cols)
    return cols
end

"""
    standardize(src, raw) -> EpiTable

Convert a decoded payload into the standard schema.

Columns are built directly rather than by assembling a `Vector{EpiObservation}` and
converting: the result is a `StructArray`, so writing it to Arrow hands over the existing
column vectors instead of transposing a million rows first.
"""
function standardize(::DelphiCovidcast, raw)
    rows = Tables.rows(raw)
    avail = _colnames(raw)
    c = _columns(rows)

    for row in rows
        tt = string(_get(row, :time_type, avail))
        lvl = parse_geo_level(string(_get(row, :geo_type, avail)))
        ps, pe = period_bounds(tt, _get(row, :time_value, avail))

        push!(c.source, _require_symbol(_get(row, :source, avail), :source))
        push!(c.signal, _require_symbol(_get(row, :signal, avail), :signal))
        push!(c.geo_level, lvl)
        push!(c.geo_id, normalize_geo_id(lvl, _get(row, :geo_value, avail)))
        push!(c.period_start, ps)
        push!(c.period_end, pe)
        push!(c.value, coerce_float(_get(row, :value, avail)))
        push!(c.stderr, coerce_float(_get(row, :stderr, avail)))
        push!(c.sample_size, coerce_float(_get(row, :sample_size, avail)))
        push!(c.issue, parse_issue(tt, _get(row, :issue, avail)))
        push!(c.lag, coerce_int(_get(row, :lag, avail)))
        push!(c.missing_code, coerce_missing_code(_get(row, :missing_value, avail)))
    end

    return StructArray{EpiObservation}(c)
end

"""
Fluview measurements, each of which becomes its own signal. A fixed list rather than
whatever keys a row carries, so a field Delphi adds later is a silent omission instead of a
bogus signal name in saved tables.
"""
const FLUVIEW_MEASURES = (:wili, :ili, :num_ili, :num_patients, :num_providers,
                          :num_age_0, :num_age_1, :num_age_2, :num_age_3,
                          :num_age_4, :num_age_5)

function standardize(::DelphiFluView, raw)
    rows = Tables.rows(raw)
    avail = _colnames(raw)
    c = _columns(rows, length(FLUVIEW_MEASURES))

    for row in rows
        lvl, gid = fluview_geo(_get(row, :region, avail))
        ps, pe = period_bounds("week", _get(row, :epiweek, avail))
        iss = parse_issue("week", _get(row, :issue, avail))
        lag = coerce_int(_get(row, :lag, avail))
        # The denominator of ili and wili. The fan-out puts it in a different row, so
        # carrying it here saves every consumer a join.
        patients = coerce_float(_get(row, :num_patients, avail))

        for m in FLUVIEW_MEASURES
            v = coerce_float(_get(row, m, avail))
            v === missing && continue
            push!(c.source, :fluview)
            push!(c.signal, m)
            push!(c.geo_level, lvl)
            push!(c.geo_id, gid)
            push!(c.period_start, ps)
            push!(c.period_end, pe)
            push!(c.value, v)
            push!(c.stderr, missing)
            push!(c.sample_size, m === :wili || m === :ili ? patients : missing)
            push!(c.issue, iss)
            push!(c.lag, lag)
            push!(c.missing_code, NOT_MISSING)
        end
    end

    return StructArray{EpiObservation}(c)
end

"""
    EpiTable(observations::AbstractVector{EpiObservation}) -> EpiTable

Build an [`EpiTable`](@ref) from loose observations. Mostly useful in tests and when
assembling data by hand.
"""
EpiTable(obs::AbstractVector{EpiObservation}) = StructArray(obs)

"""
    empty_table() -> EpiTable

A zero-row table with the right column types, for code paths that need a valid empty
result rather than an exception.
"""
empty_table() = StructArray{EpiObservation}(_columns(()))
