using Dates
using EpiDataKit: fetch_fluview, mock_response, request_key, fluview_params, fluview_geo,
                  standardize, decode_response, DelphiFluView, FLUVIEW_ENDPOINT,
                  FLUVIEW_MEASURES

function mock_for_fluview(body; status = 200, kwargs...)
    params = fluview_params(; kwargs...)
    key = request_key(FLUVIEW_ENDPOINT, params)
    return MockTransport(Dict(key => mock_response(body; status = status, request = key)))
end

const FV_QUERY = (epiweeks = "202020-202021", regions = ["nat", "hhs1"])

@testset "fluview" begin
    @testset "end to end on a recorded response" begin
        t = mock_for_fluview(fixture("fluview_success.json"); FV_QUERY...)
        tbl = fetch_fluview(; transport = t, FV_QUERY...)

        @test tbl isa EpiTable
        @test all(==(:fluview), tbl.source)
        # 4 upstream rows x 10 non-null measures each: num_age_2 is null throughout.
        @test length(tbl) == 40
        @test :num_age_2 ∉ tbl.signal
        @test Set(tbl.geo_level) == Set([NATION, HHS_REGION])
        @test Set(tbl.geo_id) == Set(["nat", "hhs1"])
    end

    @testset "one upstream row fans out into one observation per measure" begin
        # The schema holds one value per row, so a multi-measure source has to fan out.
        # This is the property that makes one schema work across sources at all.
        src = DelphiFluView()
        body = """{"result":1,"message":"success","epidata":[
            {"release_date":"2021-10-08","region":"nat","issue":202139,"epiweek":202020,
             "lag":72,"num_ili":10480,"num_patients":846493,"num_providers":2613,
             "num_age_0":788,"num_age_1":1960,"num_age_2":null,"num_age_3":4112,
             "num_age_4":2171,"num_age_5":1449,"wili":1.11444,"ili":1.23805}]}"""
        tbl = standardize(src, decode_response(src, mock_response(body)))

        @test length(tbl) == 10
        @test Set(tbl.signal) == Set(setdiff(collect(FLUVIEW_MEASURES), [:num_age_2]))
        # Everything derived from the parent row is identical across the fan-out.
        @test length(unique(tbl.period_start)) == 1
        @test length(unique(tbl.geo_id)) == 1
        @test length(unique(tbl.issue)) == 1
    end

    @testset "num_patients is carried as sample_size on the percentages only" begin
        # ili is num_ili/num_patients*100, so num_patients is its denominator. After the
        # fan-out it is a different row, and a consumer computing a CI should not have to
        # join to get it back.
        src = DelphiFluView()
        tbl = standardize(src, decode_response(src,
            mock_response(fixture("fluview_success.json"))))

        for (sig, ss) in zip(tbl.signal, tbl.sample_size)
            if sig === :wili || sig === :ili
                @test ss !== missing
            else
                @test ss === missing
            end
        end

        i = findfirst(==(:ili), tbl.signal)
        j = findfirst(==(:num_patients), tbl.signal)
        @test tbl.sample_size[i] == tbl.value[j]
    end

    @testset "epiweeks become MMWR intervals and issues become dates" begin
        src = DelphiFluView()
        tbl = standardize(src, decode_response(src,
            mock_response(fixture("fluview_success.json"))))

        # 202020 is the MMWR week Sun 2020-05-10 through Sat 2020-05-16.
        @test Date(2020, 5, 10) in tbl.period_start
        @test all(o -> o.period_end - o.period_start == Day(6), tbl)
        # issue 202139 -> the Saturday ending that epiweek.
        @test all(==(Date(2021, 10, 2)), tbl.issue)
    end

    @testset "region codes map to the right level" begin
        @test fluview_geo("nat") == (NATION, "nat")
        @test fluview_geo("hhs1") == (HHS_REGION, "hhs1")
        @test fluview_geo("hhs10") == (HHS_REGION, "hhs10")
        @test fluview_geo("cen1") == (CENSUS_DIVISION, "cen1")
        @test fluview_geo("cen9") == (CENSUS_DIVISION, "cen9")
        @test fluview_geo("ca") == (STATE, "ca")
        @test fluview_geo("NY ") == (STATE, "ny")

        # hhs11 and cen0 do not exist; a lax regex would accept them and mislabel the row.
        @test_throws ValidationError fluview_geo("hhs11")
        @test_throws ValidationError fluview_geo("hhs0")
        @test_throws ValidationError fluview_geo("cen0")
        @test_throws ValidationError fluview_geo("usa")
        @test_throws ValidationError fluview_geo("")
        @test_throws ValidationError fluview_geo(missing)
    end

    @testset "a bad region costs no request" begin
        t = MockTransport()
        @test_throws ValidationError fluview_params(epiweeks = "202020", regions = ["nat", "zz9"])
        @test_throws ValidationError fetch_fluview(; transport = t,
            epiweeks = "202020", regions = ["nat", "zz9"])
        @test isempty(t.calls)
    end

    @testset "Date ranges convert to epiweeks" begin
        p = fluview_params(epiweeks = Date(2020, 5, 10):Date(2020, 5, 17), regions = "nat")
        @test p["epiweeks"] == "202020-202021"
        @test p["regions"] == "nat"
        @test !haskey(p, "format")   # fluview is JSON-only; requesting csv would break decode
    end

    @testset "issues and lag reach the wire, as_of is not a fluview concept" begin
        p = fluview_params(epiweeks = "202020", regions = "nat", issues = "202139", lag = 3)
        @test p["issues"] == "202139"
        @test p["lag"] == "3"
        @test_throws MethodError fluview_params(epiweeks = "202020", regions = "nat", as_of = "202139")
    end

    @testset "error modes propagate" begin
        @test_throws NoResultsError fetch_fluview(;
            transport = mock_for_fluview(fixture("fluview_noresults.json"); FV_QUERY...),
            FV_QUERY...)
        @test_throws TruncatedResultsError fetch_fluview(;
            transport = mock_for_fluview(fixture("covidcast_truncated.json"); FV_QUERY...),
            FV_QUERY...)
    end
end
