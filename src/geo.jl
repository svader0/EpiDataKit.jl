# Geographic identifier normalization.

"""
All possible Delphi `geo_type` strings are mapped to [`GeoLevel`](@ref).
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
    "census_region" => CENSUS_REGION,
    "sewershed" => SEWERSHED,
    "va_facility" => VA_FACILITY,
)

"""
    parse_geo_level(s) -> GeoLevel

Map a Delphi `geo_type` string onto a [`GeoLevel`](@ref).

Throws [`ValidationError`](@ref) on an unrecognized type.
"""
function parse_geo_level(s::AbstractString)
    key = lowercase(strip(s))
    lvl = get(GEO_TYPE_MAP, key, nothing)
    lvl === nothing && throw(ValidationError(
        "unrecognized geo_type $(repr(String(s))); known: " *
        join(sort!(collect(keys(GEO_TYPE_MAP))), ", ")))
    return lvl
end

parse_geo_level(l::GeoLevel) = l

"""
    normalize_geo_id(level::GeoLevel, raw) -> String

Normalize a `geo_value` for its level.

County FIPS codes are zero-padded to five digits and HSA/HRR/DMA codes are left as
plain integers-as-strings. The padding matters: `"06075"` (San Francisco) round-trips
through a numeric CSV column as `6075`, which is a different county.

Throws [`ValidationError`](@ref) on an absent value.
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
