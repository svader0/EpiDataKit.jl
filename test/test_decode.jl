using EpiDataKit: decode_response, mock_response, check_result, try_json_envelope,
                  COVIDCAST_CSV_HEADER, format_time_values, covidcast_params
using Dates
using Tables

# Every case below is a body recorded from the live API, except the truncated one, which
# could not be triggered on demand. The point of this file is that the error contract is
# pinned to observed behaviour rather than to what the documentation implies.
@testset "decode_response" begin
    src = DelphiCovidcast()

    @testset "CSV success" begin
        tbl = decode_response(src, mock_response(fixture("covidcast_success.csv")))
        rows = collect(Tables.rows(tbl))
        @test length(rows) == 2
        @test rows[1].geo_value == "ca"
        @test rows[1].time_value == 202620
        @test rows[1].value ≈ 0.07
    end

    @testset "recorded CSV header matches the constant" begin
        # If the endpoint ever changes shape, this fails here rather than somewhere
        # confusing inside standardize.
        first_line = split(fixture("covidcast_success.csv"), '\n')[1]
        @test strip(first_line) == COVIDCAST_CSV_HEADER
    end

    @testset "empty body at 200 is how CSV mode says no results" begin
        # There is no result code in this response at all — the emptiness is the signal.
        body = fixture("covidcast_noresults.csv")
        @test isempty(strip(body))
        @test_throws NoResultsError decode_response(src, mock_response(body))
    end

    @testset "JSON mode signals no results with result -2" begin
        @test_throws NoResultsError decode_response(src, mock_response(fixture("covidcast_noresults.json")))
    end

    @testset "validation error arrives as JSON at 400 despite format=csv" begin
        resp = mock_response(fixture("covidcast_validation_error.json"); status = 400)
        err = try
            decode_response(src, resp)
            nothing
        catch e
            e
        end
        @test err isa EpidataError
        @test err.code == -1
        # The server's own message is more useful than "HTTP 400", so it must survive.
        @test occursin("missing parameter", err.message)
    end

    @testset "truncated result set is an error, not a silent partial answer" begin
        resp = mock_response(fixture("covidcast_truncated.json"))
        err = try
            decode_response(src, resp)
            nothing
        catch e
            e
        end
        @test err isa TruncatedResultsError
        @test occursin("truncated", err.message)
    end

    @testset "non-JSON error page" begin
        html = "<!doctype html>\n<title>404 Not Found</title>\n<h1>Not Found</h1>"
        err = try
            decode_response(src, mock_response(html; status = 404))
            nothing
        catch e
            e
        end
        @test err isa TransportError
        @test err.status == 404
    end

    @testset "empty body at a non-200 status is a transport failure" begin
        @test_throws TransportError decode_response(src, mock_response(""; status = 502))
    end

    @testset "unexpected 200 body" begin
        # Neither JSON nor this endpoint's CSV: refuse rather than mis-parse.
        @test_throws EpidataError decode_response(src, mock_response("some,other,csv\n1,2,3"))
    end

    @testset "a header with no data rows is an empty table, not NoResultsError" begin
        # Delphi signals "no rows matched" with a genuinely empty body, which is the case
        # above. A well-formed header carrying zero rows is a different thing and is not
        # something the endpoint has been observed to send — so it decodes to an empty
        # table rather than being mapped onto the no-results contract. Pinned here so the
        # distinction is a decision rather than an accident, and so that inventing
        # handling for it later is a visible change.
        tbl = decode_response(src, mock_response(COVIDCAST_CSV_HEADER * "\n"))
        @test isempty(collect(Tables.rows(tbl)))
    end
end

@testset "check_result" begin
    @test check_result("req", 1, "") === nothing
    @test_throws NoResultsError check_result("req", -2, "no results")
    @test_throws TruncatedResultsError check_result("req", 2, "too many results")
    @test_throws EpidataError check_result("req", -1, "bad param")
    @test_throws EpidataError check_result("req", 99, "who knows")
    @test_throws EpidataError check_result("req", nothing, "unparseable")
end

@testset "try_json_envelope" begin
    @test try_json_envelope("not json") === nothing
    @test try_json_envelope("geo_value,signal\nca,x") === nothing
    @test try_json_envelope("{\"no_result_field\": 1}") === nothing
    @test try_json_envelope("{ bad json") === nothing

    env = try_json_envelope("{\"epidata\": [], \"result\": -2, \"message\": \"no results\"}")
    @test env !== nothing
    code, msg, _ = env
    @test code == -2
    @test msg == "no results"
end

@testset "query construction" begin
    @testset "format_time_values" begin
        @test format_time_values("week", "202620-202629") == "202620-202629"
        @test format_time_values("week", 202620) == "202620"
        @test format_time_values("day", 20200601) == "20200601"
        @test format_time_values("week", [202620, 202621]) == "202620,202621"

        # Dates are converted per time_type, so callers need not compute epiweeks by hand.
        @test format_time_values("week", Date(2026, 5, 17)) == "202620"
        @test format_time_values("day", Date(2020, 6, 1)) == "20200601"
        @test format_time_values("week", Date(2026, 1, 4)) == "202601"  # zero-padded week
    end

    @testset "covidcast_params validates locally" begin
        # Catching these before sending matters: the anonymous cap is 60 requests/hour.
        @test_throws ValidationError covidcast_params(
            data_source = "nssp", signal = "s", time_type = "month",
            geo_type = "state", time_values = 202620)
        @test_throws ValidationError covidcast_params(
            data_source = "nssp", signal = "s", time_type = "week",
            geo_type = "planet", time_values = 202620)
    end

    @testset "covidcast_params requests CSV" begin
        p = covidcast_params(data_source = "nssp", signal = "pct_ed_visits_covid",
                             time_type = "week", geo_type = "state",
                             time_values = 202620, geo_value = "ca")
        @test p["format"] == "csv"
        @test p["time_type"] == "week"
        @test p["geo_value"] == "ca"
        @test !haskey(p, "as_of")
    end

    @testset "optional revision parameters" begin
        p = covidcast_params(data_source = "nssp", signal = "s", time_type = "week",
                             geo_type = "state", time_values = 202620,
                             as_of = 202630, lag = 3)
        @test p["as_of"] == "202630"
        @test p["lag"] == "3"
    end
end
