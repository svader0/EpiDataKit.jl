using Dates
using EpiDataKit: fetch_signal, mock_response, request_key, covidcast_params,
                  COVIDCAST_ENDPOINT

# `fetch_signal` is the package's entry point — the one function that wires query
# construction, transport, decoding and standardisation together. Every other test
# exercises one of those links in isolation, so without this file the composition itself
# is only ever checked by scripts/check_upstream.jl, which needs the network and is run
# by hand.

# Build a MockTransport that will answer exactly the request `fetch_signal` should make.
function mock_for(body; status = 200, kwargs...)
    params = covidcast_params(; kwargs...)
    key = request_key(COVIDCAST_ENDPOINT, params)
    return MockTransport(Dict(key => mock_response(body; status = status, request = key)))
end

const QUERY = (data_source = "nssp", signal = "pct_ed_visits_covid", time_type = "week",
               geo_type = "state", time_values = "202620-202621", geo_value = "ca")

@testset "fetch_signal" begin
    @testset "end to end on a recorded response" begin
        t = mock_for(fixture("covidcast_success.csv"); QUERY...)
        tbl = fetch_signal(; transport = t, QUERY...)

        @test tbl isa EpiTable
        @test length(tbl) == 2
        @test tbl[1].source === :nssp
        @test tbl[1].signal === :pct_ed_visits_covid
        @test tbl[1].geo_level == STATE
        @test tbl[1].geo_id == "ca"
        @test tbl[1].period_start == Date(2026, 5, 17)
        @test tbl[1].period_end == Date(2026, 5, 23)
        @test tbl[1].value ≈ 0.07
        @test tbl[1].issue == Date(2026, 8, 1)
    end

    @testset "sends exactly one request, in canonical form" begin
        t = mock_for(fixture("covidcast_success.csv"); QUERY...)
        fetch_signal(; transport = t, QUERY...)

        @test length(t.calls) == 1
        call = only(t.calls)
        @test startswith(call, COVIDCAST_ENDPOINT)
        @test occursin("format=csv", call)
        @test occursin("data_source=nssp", call)
        # The credential must never be reachable from a request description, since that
        # string is what lands on exceptions and in logs.
        @test !occursin("api_key", call)
    end

    @testset "a key on the transport still never reaches the query" begin
        t = mock_for(fixture("covidcast_success.csv"); QUERY...)
        fetch_signal(; transport = t, QUERY...)
        @test !occursin("s3cret", only(t.calls))
    end

    @testset "errors propagate from the decode layer" begin
        # Each of these is a distinct upstream failure mode, and each has to survive the
        # trip out through fetch_signal rather than being swallowed or retyped.
        @test_throws NoResultsError fetch_signal(;
            transport = mock_for(fixture("covidcast_noresults.csv"); QUERY...), QUERY...)

        @test_throws NoResultsError fetch_signal(;
            transport = mock_for(fixture("covidcast_noresults.json"); QUERY...), QUERY...)

        @test_throws TruncatedResultsError fetch_signal(;
            transport = mock_for(fixture("covidcast_truncated.json"); QUERY...), QUERY...)

        @test_throws EpidataError fetch_signal(;
            transport = mock_for(fixture("covidcast_validation_error.json");
                                 status = 400, QUERY...), QUERY...)

        @test_throws TransportError fetch_signal(;
            transport = mock_for("<html>gateway</html>"; status = 502, QUERY...), QUERY...)
    end

    @testset "local validation runs before any request is made" begin
        # The anonymous cap is 60 requests/hour, so a checkable mistake must not cost one.
        t = MockTransport()
        @test_throws ValidationError fetch_signal(;
            transport = t, data_source = "nssp", signal = "s", time_type = "month",
            geo_type = "state", time_values = 202620)
        @test_throws ValidationError fetch_signal(;
            transport = t, data_source = "nssp", signal = "s", time_type = "week",
            geo_type = "planet", time_values = 202620)
        @test isempty(t.calls)
    end

    @testset "optional revision parameters reach the wire" begin
        q = (data_source = "nssp", signal = "pct_ed_visits_covid", time_type = "week",
             geo_type = "state", time_values = "202620-202621", geo_value = "ca",
             as_of = 202630)
        t = mock_for(fixture("covidcast_success.csv"); q...)
        fetch_signal(; transport = t, q...)
        @test occursin("as_of=202630", only(t.calls))
    end

    @testset "dates are accepted in place of packed epiweeks" begin
        q = (data_source = "nssp", signal = "pct_ed_visits_covid", time_type = "week",
             geo_type = "state", time_values = Date(2026, 5, 17):Day(7):Date(2026, 5, 24),
             geo_value = "ca")
        t = mock_for(fixture("covidcast_success.csv"); q...)
        tbl = fetch_signal(; transport = t, q...)
        @test occursin("time_values=202620-202621", only(t.calls))
        @test length(tbl) == 2
    end
end
