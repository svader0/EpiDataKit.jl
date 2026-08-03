# Load: the standardised table onto disk and back.
#
# Two choices here are deliberate and mildly counterintuitive.
#
# 1. Compression is off by default. Compression and zero-copy mmap are mutually exclusive:
#    a zstd-compressed Arrow file has to decompress every buffer into fresh memory when it
#    is opened, which is why it allocates and reads far slower than an uncompressed file
#    that the OS can simply map. A cache exists to be read repeatedly by downstream
#    packages, so it should be the fast one. `compress = :zstd` is there for archival, and
#    even uncompressed Arrow is several times smaller than the JSON it came from.
#
#    Worth being precise about who gets that benefit: it is `Arrow.Table(path)`, whose
#    columns stay lazy over the mapped buffers. `load` below deliberately copies them into
#    ordinary Julia vectors so the returned table's element type is exactly
#    `EpiObservation` and `load(save(x)) == x` holds — on 500k rows that is ~69ms and
#    ~52MiB against ~0.8ms and ~0.05MiB for a lazy column scan. Callers that want the
#    zero-copy path should reach for `Arrow.Table` directly.
#
# 2. Dictionary encoding is applied per column, not globally. `Arrow.write(...;
#    dictencode = true)` encodes *every* column including the float measurements, where a
#    dictionary is overhead rather than savings. Only the columns that actually repeat —
#    the source and signal names, the geo ids, the two enums — are worth encoding.

"""
Columns worth dictionary-encoding: low cardinality and repeated on every row. A typical
query returns one source, one signal, and a handful of geo ids across thousands of rows.
"""
const DICT_ENCODED_COLUMNS = (:source, :signal, :geo_id, :geo_level, :missing_code)

"""
    save(tbl::EpiTable, path; compress = nothing) -> path

Write an [`EpiTable`](@ref) to an Arrow file.

Defaults to uncompressed so the file can be memory-mapped on the way back in. Pass
`compress = :zstd` (or `:lz4`) for archival copies that are written once and read rarely —
it trades the zero-copy read away for a substantially smaller file. Note that it is
`Arrow.Table(path)` that collects the mapping benefit in full; [`load`](@ref) copies the
columns out, for the reasons in its docstring.

The two enum columns land on disk as `int8` values carrying no Julia-specific extension
metadata, so the file is readable by anything that speaks Arrow without needing this
package — see `test/portability_check/`. (They are dictionary-encoded, so the schema
reports `dictionary<values=int8>` rather than a bare `int8` — the decoded values are the
same.)
"""
function save(tbl, path::AbstractString; compress::Union{Symbol,Nothing} = nothing)
    cols = Tables.columntable(tbl)
    encoded = NamedTuple{keys(cols)}(
        ntuple(i -> keys(cols)[i] in DICT_ENCODED_COLUMNS ?
                    Arrow.DictEncode(cols[i]) : cols[i], length(cols)))
    Arrow.write(path, encoded; compress)
    return path
end

"""
    load(path) -> EpiTable

Read an Arrow file written by [`save`](@ref) back into the standard schema.

The enum columns need explicit reconstruction. They are stored as plain `int8` precisely
so foreign readers need nothing from this package, and the cost of that choice is that
Arrow has no extension annotation telling it to call `fromarrow` on the way back — so it
returns `Int8` and this function converts. Everything else round-trips with exact type
fidelity, including `missing`s and the date columns.

Note that this materialises every column into an ordinary Julia vector, which is what
makes `load(save(x)) == x` hold exactly — it is not the zero-copy read. To scan a large
cache without paying for the copy, open it with `Arrow.Table(path)` directly and work
with the lazy columns; see the storage section of the README for the measured difference.

Throws [`StoreError`](@ref) if the file is not one of ours, rather than surfacing whatever
`KeyError` or `ArgumentError` the underlying reader happened to produce.
"""
function load(path::AbstractString)
    t = try
        Arrow.Table(path)
    catch e
        e isa InterruptException && rethrow()
        throw(StoreError(path, "could not be read as an Arrow file: " * sprint(showerror, e)))
    end

    present = Set{Symbol}(Tables.columnnames(t))
    required = fieldnames(EpiObservation)
    absent = [c for c in required if !(c in present)]
    isempty(absent) || throw(StoreError(path,
        "not an EpiDataKit table: missing column(s) " * join(absent, ", ") *
        ". Found: " * join(sort!(collect(present)), ", ")))

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
        issue        = _materialize(Union{Date,Missing}, t.issue),
        missing_code = _materialize_enum(MissingCode, t.missing_code, path),
    ))
end

# A value outside the enum means the file was written by a build that had appended a new
# level. The raw `ArgumentError: invalid value for Enum GeoLevel: 9` is technically
# correct and tells the reader nothing about what to do, so say it properly.
function _materialize_enum(::Type{T}, col, path) where {T}
    # Membership rather than a range, so a future enum with a gap in its numbering is
    # still checked correctly. Widening to `Int` first keeps a column written as int32 or
    # int64 from failing with `InexactError` instead of the error that explains itself.
    valid = Set(Int.(instances(T)))
    lo, hi = extrema(valid)
    out = Vector{T}(undef, length(col))
    @inbounds for (i, x) in enumerate(col)
        x === missing && throw(StoreError(path,
            "$(nameof(T)) column contains a null at row $i; it is non-nullable"))
        x isa Integer || throw(StoreError(path,
            "$(nameof(T)) column holds a $(typeof(x)) at row $i; expected an integer"))
        v = Int(x)
        v in valid || throw(StoreError(path,
            "$(nameof(T)) column contains $v at row $i, which this version of EpiDataKit " *
            "does not define (known: $(lo)–$(hi)). " *
            "The file was probably written by a newer version; upgrade the package."))
        out[i] = T(v)
    end
    return out
end

# Arrow hands back its own lazy column types (dictionary-encoded arrays, `String` views).
# Converting to plain Julia vectors keeps the returned `EpiTable` a normal mutable table
# whose element type matches `EpiObservation` exactly, which is what makes `load(save(x))`
# compare equal to `x`.
_materialize(::Type{T}, col) where {T} = T[convert(T, x) for x in col]
_materialize(::Type{Union{T,Missing}}, col) where {T} =
    Union{T,Missing}[x === missing ? missing : convert(T, x) for x in col]
