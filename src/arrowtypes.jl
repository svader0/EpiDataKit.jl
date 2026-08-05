# Type declarations for Arrow. `GeoLevel` and `MissingCode` are
# told to serialize as their underlying `Int8` (see `src/types.jl`).
for T in (GeoLevel, MissingCode)
    @eval ArrowTypes.ArrowKind(::Type{$T}) = ArrowTypes.PrimitiveKind()
    @eval ArrowTypes.ArrowType(::Type{$T}) = Int8
    @eval ArrowTypes.toarrow(x::$T) = Int8(x)
    @eval ArrowTypes.fromarrow(::Type{$T}, x::Int8) = $T(x)
end
