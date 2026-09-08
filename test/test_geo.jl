using EpiDataKit: parse_geo_level, normalize_geo_id, GEO_TYPE_MAP

@testset "geo" begin
    @testset "parse_geo_level" begin
        @test parse_geo_level("state") == STATE
        @test parse_geo_level("STATE") == STATE
        @test parse_geo_level("  county ") == COUNTY
        @test parse_geo_level("nation") == NATION
        @test parse_geo_level("hhs") == HHS_REGION
        @test parse_geo_level("msa") == MSA
        @test parse_geo_level("hrr") == HRR
        @test parse_geo_level("dma") == DMA

        # Present in live covidcast_meta even though it is not prominent in the docs;
        # omitting it would make real queries throw.
        @test parse_geo_level("hsa_nci") == HSA_NCI

        @test parse_geo_level(STATE) == STATE  # idempotent on an already-parsed level
    end

    @testset "unknown geo_type fails loudly" begin
        # Guessing would silently misattribute every row in the response.
        @test_throws ValidationError parse_geo_level("planet")
        @test_throws ValidationError parse_geo_level("")
    end

    @testset "county FIPS keeps its leading zero" begin
        # "06075" is San Francisco. Read as a number it becomes 6075, which is not the
        # same place, so the padding is correctness rather than cosmetics.
        @test normalize_geo_id(COUNTY, "06075") == "06075"
        @test normalize_geo_id(COUNTY, 6075) == "06075"
        @test normalize_geo_id(COUNTY, "6075") == "06075"
        @test normalize_geo_id(COUNTY, "19167") == "19167"  # already five digits
    end

    @testset "other levels are lowercased and trimmed" begin
        @test normalize_geo_id(STATE, "CA") == "ca"
        @test normalize_geo_id(STATE, " ca ") == "ca"
        @test normalize_geo_id(NATION, "US") == "us"
        @test normalize_geo_id(HHS_REGION, "1") == "1"
        # Padding is county-specific: an HHS region is a small integer, not a FIPS code.
        @test normalize_geo_id(HHS_REGION, "9") == "9"
    end

    @testset "empty geo_value rejected" begin
        @test_throws ValidationError normalize_geo_id(STATE, "")
        @test_throws ValidationError normalize_geo_id(COUNTY, "   ")
    end

    @testset "absent geo_value rejected rather than stringified" begin
        # Regression: `strip(string(missing))` is the non-empty text "missing", so it
        # sailed past the emptiness check and became a geo_id indistinguishable from a
        # real identifier. geo_id is an identity column with no null representation, so
        # the only correct answer is to refuse the row.
        @test_throws ValidationError normalize_geo_id(STATE, missing)
        @test_throws ValidationError normalize_geo_id(STATE, nothing)
        @test_throws ValidationError normalize_geo_id(COUNTY, missing)
        @test normalize_geo_id(STATE, "missing") == "missing"  # a literal string still is one
    end

    @testset "every mapped name resolves" begin
        for (name, lvl) in GEO_TYPE_MAP
            @test parse_geo_level(name) == lvl
        end
    end

    @testset "V5 geographic levels" begin
        @test parse_geo_level("census_region") === CENSUS_REGION
        @test parse_geo_level("sewershed") === SEWERSHED
        @test parse_geo_level("va_facility") === VA_FACILITY

        # On-disk values. Never renumber these.
        @test Int(CENSUS_REGION) == 9
        @test Int(SEWERSHED) == 10
        @test Int(VA_FACILITY) == 11

        # The V4 numbering must not move.
        @test Int(NATION) == 0
        @test Int(HSA_NCI) == 8

        @test normalize_geo_id(CENSUS_REGION, "1") == "1"
        @test normalize_geo_id(VA_FACILITY, "ABC") == "abc"
    end
end
