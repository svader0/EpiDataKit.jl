# Transform: whatever a source handed back becomes an `EpiTable`.
#
# `standardize` dispatches on the source tag, so each endpoint decodes its own layout while
# every one of them produces the same schema. Adding a source means adding a method here,
# not touching anything downstream.

"""
    coerce_float(x) -> Union{Float64,Missing}

Read a measurement that may arrive as a number, as a string, or not at all.

Both forms turn up in practice: CSV parsing yields real numbers, JSON mode yields strings
for the same fields. `NaN` becomes `missing` because Delphi uses it as the placeholder
that accompanies a non-zero missing code — keeping it as a float would let it propagate
silently through arithmetic instead of being handled as absent.
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

An absent code means the value is present — that is the overwhelmingly common case and
the endpoint omits the column entirely for some sources. An unrecognised code maps to
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

# Column access that tolerates a field being absent rather than null. JSON payloads from
# these APIs routinely omit a key instead of sending an explicit null, and a `KeyError`
# per row is not a useful failure mode.
#
# Where the column set comes from matters. A source that declares a `Tables.schema` — CSV,
# or any columnar table — guarantees every row carries every column, so the name set is
# computed once and reused. Row-oriented payloads with no schema (JSON) guarantee nothing:
# any individual row may omit any key. Taking the first row's keys as the answer for the
# whole payload is wrong in both directions — it silently drops values that later rows do
# carry, and it still throws `KeyError` on a later row that omits one — so those are
# checked per row instead.
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

"""
    standardize(src, raw) -> EpiTable

Convert a decoded payload into the standard schema.

Columns are built directly rather than by assembling a `Vector{EpiObservation}` and
converting: the result is a `StructArray`, so writing it to Arrow is a matter of handing
over the existing column vectors instead of transposing a million rows first.
"""
function standardize(::DelphiCovidcast, raw)
    rows = Tables.rows(raw)
    avail = _colnames(raw)
    # `HasShape` counts too — a plain vector of rows reports it rather than `HasLength`,
    # and missing that case turned every `sizehint!` below into a no-op.
    n = Base.IteratorSize(typeof(rows)) isa Union{Base.HasLength,Base.HasShape} ? length(rows) : 0

    source       = Vector{Symbol}();                  sizehint!(source, n)
    signal       = Vector{Symbol}();                  sizehint!(signal, n)
    geo_level    = Vector{GeoLevel}();                sizehint!(geo_level, n)
    geo_id       = Vector{String}();                  sizehint!(geo_id, n)
    period_start = Vector{Date}();                    sizehint!(period_start, n)
    period_end   = Vector{Date}();                    sizehint!(period_end, n)
    value        = Vector{Union{Float64,Missing}}();  sizehint!(value, n)
    stderr       = Vector{Union{Float64,Missing}}();  sizehint!(stderr, n)
    sample_size  = Vector{Union{Float64,Missing}}();  sizehint!(sample_size, n)
    issue        = Vector{Union{Date,Missing}}();     sizehint!(issue, n)
    missing_code = Vector{MissingCode}();             sizehint!(missing_code, n)

    for row in rows
        tt = string(_get(row, :time_type, avail))
        lvl = parse_geo_level(string(_get(row, :geo_type, avail)))
        ps, pe = period_bounds(tt, _get(row, :time_value, avail))

        push!(source, _require_symbol(_get(row, :source, avail), :source))
        push!(signal, _require_symbol(_get(row, :signal, avail), :signal))
        push!(geo_level, lvl)
        push!(geo_id, normalize_geo_id(lvl, _get(row, :geo_value, avail)))
        push!(period_start, ps)
        push!(period_end, pe)
        push!(value, coerce_float(_get(row, :value, avail)))
        push!(stderr, coerce_float(_get(row, :stderr, avail)))
        push!(sample_size, coerce_float(_get(row, :sample_size, avail)))
        push!(issue, parse_issue(tt, _get(row, :issue, avail)))
        push!(missing_code, coerce_missing_code(_get(row, :missing_value, avail)))
    end

    return StructArray{EpiObservation}((; source, signal, geo_level, geo_id, period_start,
                                        period_end, value, stderr, sample_size, issue,
                                        missing_code))
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
empty_table() = StructArray{EpiObservation}((
    source = Symbol[], signal = Symbol[], geo_level = GeoLevel[], geo_id = String[],
    period_start = Date[], period_end = Date[], value = Union{Float64,Missing}[],
    stderr = Union{Float64,Missing}[], sample_size = Union{Float64,Missing}[],
    issue = Union{Date,Missing}[], missing_code = MissingCode[],
))
