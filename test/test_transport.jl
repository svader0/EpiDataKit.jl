using Base64
using Dates
using EpiDataKit: canonical_query, request_key, auth_headers, backoff_delay, fetch_raw,
                  mock_response, ratelimit, scrub_secrets, covidcast_params, is_retryable,
                  EpiResponse, DELPHI_BASE_URL

@testset "transport" begin
    @testset "canonical_query is order-independent" begin
        a = canonical_query(Dict("b" => "2", "a" => "1", "c" => "3"))
        b = canonical_query(Dict("c" => "3", "a" => "1", "b" => "2"))
        @test a == b == "a=1&b=2&c=3"
    end

    @testset "canonical_query escapes" begin
        q = canonical_query(Dict("time_values" => "202620-202629", "geo_value" => "*"))
        @test occursin("geo_value=%2A", q)
        @test occursin("time_values=202620-202629", q)
    end

    @testset "API key never reaches the query string" begin
        params = covidcast_params(
            data_source = "nssp", signal = "pct_ed_visits_covid",
            time_type = "week", geo_type = "state",
            time_values = "202620", geo_value = "ca",
        )
        key = request_key("covidcast/", params)
        @test !occursin("api_key", key)
        @test !occursin("secret", key)
    end

    @testset "API key travels as HTTP Basic" begin
        t = HTTPTransport(api_key = "s3cret")
        hs = auth_headers(t)
        @test length(hs) == 1
        name, value = only(hs)
        @test name == "Authorization"
        @test startswith(value, "Basic ")
        # epidata:s3cret
        @test value == "Basic " * base64encode("epidata:s3cret")
    end

    @testset "no key means no auth header" begin
        @test isempty(auth_headers(HTTPTransport(api_key = nothing)))
        @test isempty(auth_headers(HTTPTransport(api_key = "")))
    end

    @testset "scrub_secrets" begin
        @test scrub_secrets("covidcast/?api_key=abc123&signal=x") ==
              "covidcast/?api_key=[REDACTED]&signal=x"
        @test scrub_secrets("covidcast/?API_KEY=abc&b=1") == "covidcast/?API_KEY=[REDACTED]&b=1"
        @test scrub_secrets("https://user:pw@host/path") == "https://[REDACTED]@host/path"
        @test scrub_secrets("covidcast/?signal=x") == "covidcast/?signal=x"
    end

    @testset "scrub_secrets covers the other credential spellings" begin
        # Regression: only api_key/apikey/auth/token/password were matched, so several
        # ordinary ways of naming a credential went through in the clear.
        for s in ["covidcast/?key=abc123", "covidcast/?secret=abc",
                  "covidcast/?api-key=abc", "covidcast/?access_token=abc",
                  "covidcast/?accessToken=abc", "covidcast/?passwd=abc",
                  "covidcast/?AUTHORIZATION=abc"]
            @test occursin("[REDACTED]", scrub_secrets(s))
            @test !occursin("abc", scrub_secrets(s))
        end

        # An Authorization header value decodes straight back to the key, so it counts.
        scrubbed = scrub_secrets("Authorization: Basic " * base64encode("epidata:s3cret"))
        @test occursin("[REDACTED]", scrubbed)
        @test !occursin(base64encode("epidata:s3cret"), scrubbed)
        @test occursin("[REDACTED]", scrub_secrets("Authorization: Bearer abc.def.ghi"))

        # Delphi's real parameters must survive untouched; over-redaction here would
        # make every error message useless for debugging.
        intact = "covidcast/?data_source=nssp&format=csv&geo_type=state&geo_value=ca" *
                 "&signal=pct_ed_visits_covid&time_type=week&time_values=202620-202629"
        @test scrub_secrets(intact) == intact
    end

    @testset "errors carry a scrubbed request" begin
        e = NoResultsError("covidcast/?api_key=hunter2&signal=x")
        @test !occursin("hunter2", e.request)
        @test occursin("[REDACTED]", e.request)
    end

    @testset "MockTransport records what was sent" begin
        params = Dict("b" => "2", "a" => "1")
        key = request_key("covidcast/", params)
        t = MockTransport(Dict(key => mock_response("body")))

        resp = fetch_raw(t, "covidcast/", params)
        @test String(resp.body) == "body"
        @test t.calls == [key]
        @test t.calls[1] == "covidcast/?a=1&b=2"
    end

    @testset "MockTransport rejects an unknown key" begin
        # Returning empty instead would let a test pass for the wrong reason.
        t = MockTransport(Dict("covidcast/?a=1" => mock_response("x")))
        @test_throws ValidationError fetch_raw(t, "covidcast/", Dict("a" => "2"))
        @test length(t.calls) == 1  # the attempt is still recorded
    end

    @testset "rate-limit headers parsed when present" begin
        resp = mock_response("x"; headers = Dict(
            "x-my-limit" => "60", "x-my-remaining" => "55",
            "x-my-reset" => "1785654587", "retry-after" => "717"))
        rl = ratelimit(resp)
        @test rl.limit == 60
        @test rl.remaining == 55
        @test rl.retry_after == 717
        @test rl.reset == unix2datetime(1785654587)
    end

    @testset "absent rate-limit headers are normal" begin
        # Delphi is load-balanced and only some nodes emit them, so this is the common
        # case rather than an error.
        rl = ratelimit(mock_response("x"))
        @test rl.limit === nothing
        @test rl.remaining === nothing
        @test rl.reset === nothing
        @test rl.retry_after === nothing
    end

    @testset "retryable statuses" begin
        @test is_retryable(429)
        @test is_retryable(500)
        @test is_retryable(503)
        # A 4xx will be exactly as wrong the second time, and retrying burns quota.
        @test !is_retryable(400)
        @test !is_retryable(404)
        @test !is_retryable(200)
    end

    @testset "backoff honours Retry-After over its own guess" begin
        t = HTTPTransport(base_delay = 1.0, max_delay = 30.0)
        @test backoff_delay(t, 1, 7) == 7.0
        @test backoff_delay(t, 3, 7) == 7.0
        @test backoff_delay(t, 1, 600) == 30.0  # still capped by max_delay
    end

    @testset "backoff grows and stays jittered within bounds" begin
        t = HTTPTransport(base_delay = 1.0, max_delay = 30.0)
        for attempt in 1:5
            base = min(1.0 * 2.0^(attempt - 1), 30.0)
            for _ in 1:50
                d = backoff_delay(t, attempt, nothing)
                @test 0.5 * base <= d <= 1.5 * base
            end
        end
    end

    @testset "default base URL" begin
        @test HTTPTransport().base_url == DELPHI_BASE_URL
        @test endswith(DELPHI_BASE_URL, "/")
    end

    @testset "v5_transport defaults" begin
        t = EpiDataKit.v5_transport(api_key = "k")
        @test t.base_url == EpiDataKit.DELPHI_V5_BASE_URL
        @test t.auth === :token
        @test EpiDataKit.HTTPTransport().auth === :basic
        @test_throws EpiDataKit.ValidationError HTTPTransport(auth = :bearer)
    end

    @testset "next_link" begin
        url = "http://delphi.cmu.edu/epidata/v5/archive/?source=nssp&header=false"
        r = mock_response("x"; headers = Dict("Link" => "<$url>; rel=\"next\""))
        @test EpiDataKit.next_link(r) == url

        @test EpiDataKit.next_link(mock_response("x")) === nothing
        # A Link header that is not a next page must not be followed.
        @test EpiDataKit.next_link(
            mock_response("x"; headers = Dict("Link" => "<$url>; rel=\"prev\""))) === nothing
    end
end
