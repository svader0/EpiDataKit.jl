# Geographic identifier normalisation.
#
# Delphi's `geo_value` is already fairly clean, but it arrives as a bare string whose
# meaning depends on the accompanying `geo_type`, and CSV parsing will happily strip the
# leading zero off a FIPS code that looks like a number. Both problems are fixed here so
# nothing downstream has to know about them.

"""
Delphi `geo_type` strings mapped to [`GeoLevel`](@ref).

`hsa_nci` is included because it appears in live `covidcast_meta` even though it is not
prominent in the docs; omitting it would make real queries throw.
"""
const GEO_TYPE_MAP = Dict{String,GeoLevel}(
    "nation" => NATION,
    "hhs" => HHS_REGION,
    "hhs_region" => HHS_REGION,
    "census_division" => CENSUS_DIVISION,
    "state" => STATE,
    "county" => COUNTY,
    "msa" => MSA,
    "hrr" => HRR,
    "dma" => DMA,
    "hsa_nci" => HSA_NCI,
)

"""
    parse_geo_level(s) -> GeoLevel

Map a Delphi `geo_type` string onto a [`GeoLevel`](@ref).

Throws [`ValidationError`](@ref) on an unrecognised type rather than guessing. A wrong
geo level silently misattributes every row in the response, so failing loudly on a new
upstream geo type is the safer default.
"""
function parse_geo_level(s::AbstractString)
    key = lowercase(strip(s))
    lvl = get(GEO_TYPE_MAP, key, nothing)
    lvl === nothing && throw(ValidationError(
        "unrecognised geo_type $(repr(String(s))); known: " *
        join(sort!(collect(keys(GEO_TYPE_MAP))), ", ")))
    return lvl
end

parse_geo_level(l::GeoLevel) = l

"""
    normalize_geo_id(level::GeoLevel, raw) -> String

Canonicalise a `geo_value` for its level.

County FIPS codes are zero-padded to five digits and HSA/HRR/DMA codes are left as
plain integers-as-strings. The padding matters: `"06075"` (San Francisco) round-trips
through a numeric CSV column as `6075`, which is a different, real county — Sioux County,
Iowa is `19167`, but four-digit codes collide with genuine five-digit ones once the zero
is gone. Everything else is lowercased and trimmed.

Throws [`ValidationError`](@ref) on an absent value. `geo_id` is an identity column and
non-nullable in the schema, so there is no correct string to substitute — and the obvious
accident, letting `string(missing)` through, yields the literal `"missing"`, which is
indistinguishable from a real identifier once it is in the table.
"""
function normalize_geo_id(level::GeoLevel, raw)
    s = strip(string(raw))
    isempty(s) && throw(ValidationError("empty geo_value at level $level"))
    if level == COUNTY
        # A county code that arrived numerically has lost its leading zero.
        return all(isdigit, s) ? lpad(s, 5, '0') : lowercase(s)
    else
        return lowercase(s)
    end
end

normalize_geo_id(level::GeoLevel, ::Missing) =
    throw(ValidationError("absent geo_value at level $level; geo_id cannot be null"))
normalize_geo_id(level::GeoLevel, ::Nothing) =
    throw(ValidationError("absent geo_value at level $level; geo_id cannot be null"))
