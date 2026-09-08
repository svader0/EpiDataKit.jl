using Base64
using CodecZlib
using HTTP
using Logging
using EpiDataKit: HTTPTransport, fetch_raw, ratelimit, body_string, TransportError

# Exercises the *real* HTTP path against a throwaway server on localhost.
# Fully offline and deterministic. Nothing here touches the network.
#
# Everything else in the suite goes through MockTransport, which is a different method of
# `fetch_raw` entirely, so without this file, `fetch_raw(::HTTPTransport, ...)` has zero
# coverage and mistakes in it are invisible.

@testset "HTTPTransport against a local server" begin
    hits = Dict{String,Int}()

    function handler(req)
        path = HTTP.URI(req.target).path
        hits[path] = get(hits, path, 0) + 1

        if path == "/ok"
            return HTTP.Response(200,
                ["X-My-Limit" => "60", "X-My-Remaining" => "55",
                 "X-My-Reset" => "1785654587", "Content-Type" => "text/csv"],
                "hello")
        elseif path == "/echo"
            # Report back exactly what arrived, so tests can assert on the wire format.
            auth = HTTP.header(req, "Authorization", "")
            token = HTTP.header(req, "token", "")
            return HTTP.Response(200, "target=$(req.target)\nauth=$auth\ntoken=$token")
        elseif path == "/flaky"
            # Fails twice, then succeeds; should be retried through to success.
            return hits[path] < 3 ? HTTP.Response(500, "server error") :
                                    HTTP.Response(200, "recovered")
        elseif path == "/bad"
            return HTTP.Response(400, "{\"result\": -1, \"message\": \"nope\"}")
        elseif path == "/empty"
            return HTTP.Response(200, "")
        elseif path == "/big"
            # Gzipped, because the size cap only applies while decompressing.
            return HTTP.Response(200, ["Content-Encoding" => "gzip"],
                                 transcode(GzipCompressor, repeat("row\n", 20_000)))
        elseif path == "/lowquota"
            return HTTP.Response(200,
                ["X-My-Limit" => "60", "X-My-Remaining" => "3"], "hello")
        end
        return HTTP.Response(404, "<html>not found</html>")
    end

    server = HTTP.serve!(handler, "127.0.0.1", 8099; listenany = true)
    base = "http://127.0.0.1:$(server.bound_port)"
    # Retries must be fast here, or the retry tests dominate the suite's runtime.
    transport(; kw...) = HTTPTransport(; base_url = base, base_delay = 0.01,
                                       max_delay = 0.05, kw...)

    try
        @testset "successful request becomes an EpiResponse" begin
            resp = fetch_raw(transport(), "ok", Dict("a" => "1"))
            @test resp.status == 200
            @test body_string(resp) == "hello"
            @test resp.request == "ok?a=1"
        end

        @testset "header names are lowercased" begin
            resp = fetch_raw(transport(), "ok", Dict("a" => "1"))
            # The server sent "X-My-Limit"; lookups downstream assume lowercase.
            @test haskey(resp.headers, "x-my-limit")
            @test resp.headers["content-type"] == "text/csv"
        end

        @testset "rate-limit headers survive a real round trip" begin
            rl = ratelimit(fetch_raw(transport(), "ok", Dict("a" => "1")))
            @test rl.limit == 60
            @test rl.remaining == 55
            @test rl.reset == unix2datetime(1785654587)
        end

        @testset "a nearly exhausted quota warns" begin
            # Callers only ever see the decoded table, so without this the anonymous
            # 60/hour limit is invisible right up until it becomes a 429 mid-analysis.
            @test_logs (:warn, r"quota") match_mode = :any begin
                fetch_raw(transport(), "lowquota", Dict("a" => "1"))
            end
            # Plenty remaining: no warning. `/ok` reports 55.
            @test_logs min_level = Logging.Warn begin
                fetch_raw(transport(), "ok", Dict("a" => "1"))
            end
        end

        @testset "query parameters are actually sent, sorted" begin
            resp = fetch_raw(transport(), "echo", Dict("b" => "2", "a" => "1"))
            body = body_string(resp)
            @test occursin("a=1", body)
            @test occursin("b=2", body)
        end

        @testset "API key is sent as a header, never in the URL" begin
            resp = fetch_raw(transport(api_key = "s3cret"), "echo",
                             Dict("signal" => "x"))
            body = body_string(resp)
            target = split(body, '\n')[1]

            @test occursin("auth=Basic " * base64encode("epidata:s3cret"), body)
            # The thing that must never happen: a credential in a loggable URL.
            @test !occursin("s3cret", target)
            @test !occursin("api_key", target)
        end

        @testset "no key means no Authorization header" begin
            resp = fetch_raw(transport(api_key = nothing), "echo", Dict("signal" => "x"))
            @test occursin("auth=\n", body_string(resp) * "\n")
        end

        @testset "5xx is retried through to success" begin
            resp = fetch_raw(transport(max_retries = 3), "flaky", Dict())
            @test resp.status == 200
            @test body_string(resp) == "recovered"
            @test hits["/flaky"] == 3  # failed twice, succeeded on the third
        end

        @testset "4xx is not retried" begin
            # A malformed request will be exactly as malformed next time, and each retry
            # spends one of the 60 requests/hour.
            resp = fetch_raw(transport(max_retries = 3), "bad", Dict())
            @test resp.status == 400
            @test hits["/bad"] == 1
        end

        @testset "retries give up and return the last response" begin
            empty!(hits)
            # /flaky needs 3 attempts to succeed; allow only 1, so it must give up.
            resp = fetch_raw(transport(max_retries = 1), "flaky", Dict())
            @test resp.status == 500
            @test hits["/flaky"] == 2  # initial attempt plus one retry
        end

        @testset "404 with a body comes back intact for decoding" begin
            # status_exception = false is what makes this reachable; HTTP.jl would
            # otherwise throw and decode_response would never see the body.
            resp = fetch_raw(transport(), "nope", Dict())
            @test resp.status == 404
            @test occursin("not found", body_string(resp))
        end

        @testset "empty 200 body is preserved" begin
            resp = fetch_raw(transport(), "empty", Dict())
            @test resp.status == 200
            @test isempty(body_string(resp))
        end

        @testset "connection failure becomes a TransportError" begin
            # Nothing is listening on this port.
            dead = HTTPTransport(base_url = "http://127.0.0.1:1", max_retries = 0,
                                 base_delay = 0.01, max_delay = 0.02)
            @test_throws TransportError fetch_raw(dead, "ok", Dict())
        end

        @testset "an oversized response is explained, and not retried" begin
            # HTTP.jl caps decoded bodies at 64 MiB by default, which real county-level
            # queries exceed. Its own error names only that internal keyword. Retrying it
            # would re-download the same oversized body three more times.
            empty!(hits)
            t = transport(max_response_bytes = 1024, max_retries = 3)
            err = try; fetch_raw(t, "big", Dict("a" => "1")); catch e; e; end
            @test err isa TransportError
            @test occursin("max_response_bytes", err.body_excerpt)
            @test occursin("Narrow the query", err.body_excerpt)
            @test hits["/big"] == 1

            # Comfortably under the cap: the same body comes back whole.
            resp = fetch_raw(transport(max_response_bytes = 10^7), "big", Dict("a" => "1"))
            @test length(body_string(resp)) == 80_000
        end

        @testset "an explicit timeout still makes a working request" begin
            # Catches a timeout keyword HTTP.jl has renamed or dropped. Nothing here can
            # assert the timeout fires: that needs real routing, and this suite is offline.
            resp = fetch_raw(transport(timeout = 5), "ok", Dict("a" => "1"))
            @test resp.status == 200
            @test body_string(resp) == "hello"
        end

        @testset "V5 token auth" begin
            t = HTTPTransport(base_url = base, api_key = "sekrit", auth = :token, max_retries = 0)
            body = body_string(fetch_raw(t, "echo", Dict("a" => "1")))

            @test occursin("token=sekrit", body) || occursin("token: sekrit", body)
            @test !occursin("Basic", body)
            # The key must never reach the query string.
            @test !occursin("sekrit", split(body, '\n')[1])
        end
    finally
        close(server)
    end
end
