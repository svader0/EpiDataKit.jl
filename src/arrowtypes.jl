# Arrow.jl has no native mapping for a Julia `@enum`, so `GeoLevel` and `MissingCode` are
# taught to serialise as their underlying `Int8`.
#
# Note what is deliberately absent: no `ArrowTypes.arrowname` / `JuliaType` registration.
# Registering an extension name would let Arrow round-trip the enum automatically, but it
# stamps a `JuliaLang.*` annotation into the schema that foreign readers must be prepared
# to ignore. Keeping the columns as plain `int8` means a Go, Python, or R user needs
# nothing from this package to read the file, which is the whole point of writing Arrow.
# `test/portability_check/` checks this from outside Julia, where a leaked annotation is
# actually visible.
#
# The cost of that choice: without an extension name Arrow has no way to know it should
# call `fromarrow`, so `Arrow.Table` hands these two columns back as raw `Int8`. `load`
# in store.jl reconstructs them explicitly. `fromarrow` is still defined here because it
# keeps the conversion in one place and makes the reconstruction obvious at the call site.
for T in (GeoLevel, MissingCode)
    @eval ArrowTypes.ArrowKind(::Type{$T}) = ArrowTypes.PrimitiveKind()
    @eval ArrowTypes.ArrowType(::Type{$T}) = Int8
    @eval ArrowTypes.toarrow(x::$T) = Int8(x)
    @eval ArrowTypes.fromarrow(::Type{$T}, x::Int8) = $T(x)
end
