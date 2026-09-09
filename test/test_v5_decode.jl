using Dates
using EpiDataKit: decode_v5, v5_error_message, mock_response, V5_KEY_HEADER,
                  NoResultsError, EpidataError, TransportError
using Tables

const V5_ROWS = V5_KEY_HEADER * ",value\n" *
                "pct_ed_visits_covid,2026-06-26,state,ak,source,2022-10-01,1.61\n" *
                "pct_ed_visits_covid,2026-06-26,state,ak,source,2022-10-08,1.31\n"

@testset "decode_v5" begin
    @testset "rows come back as a table" begin
        t = Tables.columntable(decode_v5(mock_response(V5_ROWS)))
        @test length(t.value) == 2
        @test t.geo_value == ["ak", "ak"]
        @test t.reference_time[1] == Date(2022, 10, 1)
    end

    @testset "a header-only body means no rows" begin
        @test_throws NoResultsError decode_v5(mock_response(V5_KEY_HEADER * ",value\n"))
        @test_throws NoResultsError decode_v5(mock_response(V5_KEY_HEADER * ",value"))
    end

    @testset "an empty body is a transport failure, not no-rows" begin
        @test_throws TransportError decode_v5(mock_response(""))
        @test_throws TransportError decode_v5(mock_response(""; status = 500))
    end

    @testset "422 carries the server's own message" begin
        body = """{"detail":[{"type":"literal_error","loc":["query","fill_method"],""" *
               """"msg":"Input should be 'fill_ave', 'fill_zero' or 'source'","input":"ave"}]}"""
        e = try
            decode_v5(mock_response(body; status = 422))
            nothing
        catch err
            err
        end
        @test e isa EpidataError
        @test e.code == 422
        @test occursin("fill_method", e.message)
        @test occursin("Input should be", e.message)
    end

    @testset "a 200 body that is not our CSV is an error" begin
        @test_throws EpidataError decode_v5(mock_response("<html>hello</html>"))
        @test_throws EpidataError decode_v5(mock_response("a,b,c\n1,2,3\n"))
    end

    @testset "a non-2xx that is not JSON is a transport error" begin
        @test_throws TransportError decode_v5(mock_response("<html>502</html>"; status = 502))
    end

    @testset "the ci-bearing header decodes too" begin
        body = V5_KEY_HEADER * ",ci_lower,ci_upper,value\n" *
               "pct_cough_2_plus_7dav,2026-04-10,state,al,source,2023-01-07,10.6,15.5,12.9\n"
        t = Tables.columntable(decode_v5(mock_response(body)))
        @test t.ci_lower ≈ [10.6]
        @test t.value ≈ [12.9]
    end

    @testset "geo_value keeps its leading zero" begin
        body = V5_KEY_HEADER * ",value\n" *
               "pct_ed_visits_covid,2026-06-26,county,06075,source,2022-10-01,1.61\n"
        @test Tables.columntable(decode_v5(mock_response(body))).geo_value == ["06075"]
    end

    @testset "a leading BOM does not defeat the header gate" begin
        bom = "﻿"
        t = Tables.columntable(decode_v5(mock_response(bom * V5_ROWS)))
        @test length(t.value) == 2
        @test_throws NoResultsError decode_v5(mock_response(bom * V5_KEY_HEADER * ",value\n"))
    end

    @testset "the recorded archive page decodes" begin
        t = Tables.columntable(decode_v5(mock_response(fixture("v5_archive_success.csv"))))
        @test !isempty(t.value)
        @test all(d -> d isa Date, t.reference_time)
    end

    @testset "v5_error_message" begin
        @test v5_error_message("not json") === nothing
        @test v5_error_message("""{"detail":[{"loc":["query","x"],"msg":"bad"}]}""") ==
              "query.x: bad"
        @test v5_error_message("""{"detail":[{"loc":["query"],"msg":"a"},""" *
                               """{"loc":["query","y"],"msg":"b"}]}""") ==
              "query: a; query.y: b"
    end
end
