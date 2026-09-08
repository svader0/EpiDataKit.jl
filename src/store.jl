"""
Columns worth dictionary-encoding: low cardinality and repeated on every row. Encoding the
float measurements too costs more than it saves. See the README's storage section.
"""
const DICT_ENCODED_COLUMNS = (:source, :signal, :geo_id, :geo_level, :fill_method, :missing_code)

"""
    save(tbl::EpiTable, path; compress = nothing) -> path

Write an [`EpiTable`](@ref) to an Arrow file.

Defaults to uncompressed so the file can be memory-mapped by [`scan`](@ref) on the way back
in; compression and mmap are mutually exclusive. Pass `compress = :zstd` (or `:lz4`) for
archival copies that are written once and read rarely.

The two enum columns land on disk as `int8` carrying no Julia-specific extension metadata,
so the file is readable by anything that speaks Arrow without needing this package. See
`test/portability_check/`.
"""
function save(tbl::EpiTable, path::AbstractString; compress::Union{Symbol,Nothing} = nothing)
    cols = Tables.columntable(tbl)
    encoded = NamedTuple{keys(cols)}(
        ntuple(i -> keys(cols)[i] in DICT_ENCODED_COLUMNS ?
                    Arrow.DictEncode(cols[i]) : cols[i], length(cols)))
    Arrow.write(path, encoded; compress, metadata = _provenance_metadata())
    return path
end

"""
Schema generation for the on-disk layout. Bump only on a change that an older reader
cannot handle; appending an enum value is not one, since [`load`](@ref) already reports
unknown values with a message telling the reader to upgrade.

Generation 2 added `ci_lower`, `ci_upper` and `fill_method`. A generation 1 file is still
readable: [`load`](@ref) and [`scan`](@ref) supply the absent columns.
"""
const SCHEMA_VERSION = "2"

_provenance_metadata() = Dict(
    "epidatakit.saved_at" => Dates.format(now(UTC), dateformat"yyyy-mm-dd\THH:MM:SS\Z"),
    "epidatakit.version" => string(pkgversion(@__MODULE__)),
    "epidatakit.schema" => SCHEMA_VERSION,
)

"""
    provenance(path) -> NamedTuple

When a file was written, by which version of this package, and against which schema.

A saved file is an artifact. It holds what the source said at the
moment it was fetched, and nothing re-checks that later. `saved_at` is what lets a reader
notice they are looking at numbers that have since been revised.

Returns `missing` fields for a file written by a build predating this metadata.
"""
function provenance(path::AbstractString)
    t = try
        Arrow.Table(path)
    catch e
        e isa InterruptException && rethrow()
        throw(StoreError(path, "could not be read as an Arrow file: " * sprint(showerror, e)))
    end
    m = something(Arrow.getmetadata(t), Dict{String,String}())
    get2(k) = haskey(m, k) ? m[k] : missing
    return (saved_at = get2("epidatakit.saved_at"),
            version = get2("epidatakit.version"),
            schema = get2("epidatakit.schema"))
end

# Columns a generation 1 file carries. A file missing any of these is not ours; a file
# missing only the generation 2 additions is, and gets them filled in.
const V1_COLUMNS = (:source, :signal, :geo_level, :geo_id, :period_start, :period_end,
                    :value, :stderr, :sample_size, :issue, :lag, :missing_code)

# Open, and reject anything that is not one of ours before a column access turns into a
# bare KeyError.
function _open_checked(path::AbstractString)
    t = try
        Arrow.Table(path)
    catch e
        e isa InterruptException && rethrow()
        throw(StoreError(path, "could not be read as an Arrow file: " * sprint(showerror, e)))
    end

    present = Set{Symbol}(Tables.columnnames(t))
    absent = [c for c in V1_COLUMNS if !(c in present)]
    isempty(absent) || throw(StoreError(path,
        "not an EpiDataKit table: missing column(s) " * join(absent, ", ") *
        ". Found: " * join(sort!(collect(present)), ", ")))
    return t
end

# Generation 1 predates these columns. It also predates any imputation, so every row it
# holds came straight from the publisher.
_col_or(t, name::Symbol, fallback) =
    name in Tables.columnnames(t) ? Tables.getcolumn(t, name) : fallback

"""
    load(path) -> EpiTable

Read an Arrow file written by [`save`](@ref) back into the standard schema.

Every column is copied into an ordinary Julia vector, making the result mutable and
`load(save(x)) == x` exact. [`scan`](@ref) is the zero-copy alternative when you need
neither. The enum columns are reconstructed explicitly: they carry no Arrow extension
annotation, by design, so nothing tells Arrow to convert them back from `int8`.

Throws [`StoreError`](@ref) if the file is not one of ours, rather than surfacing whatever
`KeyError` or `ArgumentError` the underlying reader happened to produce.
"""
function load(path::AbstractString)
    t = _open_checked(path)
    n = length(t.source)
    return StructArray{EpiObservation}((
        source       = _materialize(Symbol, t.source),
        signal       = _materialize(Symbol, t.signal),
        geo_level    = _materialize_enum(GeoLevel, t.geo_level, path),
        geo_id       = _materialize(String, t.geo_id),
        period_start = collect(t.period_start),
        period_end   = collect(t.period_end),
        value        = _materialize(Union{Float64,Missing}, t.value),
        stderr       = _materialize(Union{Float64,Missing}, t.stderr),
        sample_size  = _materialize(Union{Float64,Missing}, t.sample_size),
        ci_lower     = _materialize(Union{Float64,Missing},
                                    _col_or(t, :ci_lower, Missing[missing for _ in 1:n])),
        ci_upper     = _materialize(Union{Float64,Missing},
                                    _col_or(t, :ci_upper, Missing[missing for _ in 1:n])),
        issue        = _materialize(Union{Date,Missing}, t.issue),
        lag          = _materialize(Union{Int,Missing}, t.lag),
        fill_method  = _materialize(Symbol, _col_or(t, :fill_method, fill(:source, n))),
        missing_code = _materialize_enum(MissingCode, t.missing_code, path),
    ))
end

# An out-of-range value means the file came from a build that had appended a new enum
# entry. Bare `ArgumentError: invalid value for Enum GeoLevel: 9` is correct but tells the
# reader nothing to do about it. Separate from the conversion because `scan` needs the
# check without the copy.
function _check_enum(::Type{T}, col, path) where {T}
    # Membership rather than a range tolerates a future gap in the numbering; widening to
    # `Int` keeps an int32/int64 column from throwing `InexactError` instead of this.
    valid = Set(Int.(instances(T)))
    lo, hi = extrema(valid)

    # `save` dictionary-encodes these columns, so every distinct value already sits in a
    # dictionary of a handful of entries. Checking that instead of every row keeps
    # `scan`'s open cost independent of row count. A file written by anything else falls
    # back to the row scan, which is slower but never wrong.
    dict = col isa Arrow.DictEncoded && !(Missing <: eltype(col))
    vals = dict ? col.encoding.data : col
    loc(i) = dict ? "in its dictionary" : "at row $i"

    @inbounds for (i, x) in enumerate(vals)
        x === missing && throw(StoreError(path,
            "$(nameof(T)) column contains a null $(loc(i)); it is non-nullable"))
        x isa Integer || throw(StoreError(path,
            "$(nameof(T)) column holds a $(typeof(x)) $(loc(i)); expected an integer"))
        v = Int(x)
        v in valid || throw(StoreError(path,
            "$(nameof(T)) column contains $v $(loc(i)), which this version of EpiDataKit " *
            "does not define (known: $(lo) to $(hi)). " *
            "The file was probably written by a newer version; upgrade the package."))
    end
    return col
end

function _materialize_enum(::Type{T}, col, path) where {T}
    _check_enum(T, col, path)
    return T[T(Int(x)) for x in col]
end

# Lazy counterpart: converts on access so `scan` never copies the column.
struct EnumView{T,A} <: AbstractVector{T}
    data::A
end
EnumView{T}(a::A) where {T,A} = EnumView{T,A}(a)
Base.size(v::EnumView) = size(v.data)
Base.IndexStyle(::Type{<:EnumView}) = IndexLinear()
Base.@propagate_inbounds Base.getindex(v::EnumView{T}, i::Int) where {T} = T(Int(v.data[i]))

# `scan` must not allocate a column per row for a generation 1 file, which is the whole
# point of memory-mapping it.
struct ConstView{T} <: AbstractVector{T}
    value::T
    len::Int
end
Base.size(v::ConstView) = (v.len,)
Base.IndexStyle(::Type{<:ConstView}) = IndexLinear()
Base.@propagate_inbounds Base.getindex(v::ConstView, ::Int) = v.value

_const_missing(n::Int) = ConstView{Union{Float64,Missing}}(missing, n)

"""
    scan(path) -> EpiTable

Open an Arrow file without copying it. The lazy counterpart to [`load`](@ref).

The file is memory-mapped and columns are read on access, so opening costs about 80x less
time and 1000x less memory than `load` (`bench/size_and_reload.jl`). The element type is
still exactly `EpiObservation` and `scan(p) == load(p)`.

The result is read-only: writing to a column throws `ReadOnlyMemoryError`. The file also
has to outlive the table, since deleting or overwriting it while a scanned table is alive
is undefined. POSIX keeps the mapping valid after `rm`; other platforms do not.

Use `load` instead when you intend to modify the table.
"""
function scan(path::AbstractString)
    t = _open_checked(path)
    n = length(t.source)
    return StructArray{EpiObservation}((
        source       = t.source,
        signal       = t.signal,
        geo_level    = EnumView{GeoLevel}(_check_enum(GeoLevel, t.geo_level, path)),
        geo_id       = t.geo_id,
        period_start = t.period_start,
        period_end   = t.period_end,
        value        = t.value,
        stderr       = t.stderr,
        sample_size  = t.sample_size,
        ci_lower     = _col_or(t, :ci_lower, _const_missing(n)),
        ci_upper     = _col_or(t, :ci_upper, _const_missing(n)),
        issue        = t.issue,
        lag          = t.lag,
        fill_method  = _col_or(t, :fill_method, ConstView(:source, n)),
        missing_code = EnumView{MissingCode}(_check_enum(MissingCode, t.missing_code, path)),
    ))
end

# Arrow hands back its own lazy column types: dictionary-encoded arrays, `String` views.
_materialize(::Type{T}, col) where {T} = T[convert(T, x) for x in col]
_materialize(::Type{Union{T,Missing}}, col) where {T} =
    Union{T,Missing}[x === missing ? missing : convert(T, x) for x in col]
