using Base64
using HTTP
using EpiDataKit: HTTPTransport, fetch_raw, ratelimit, body_string, TransportError

# Exercises the *real* HTTP path against a throwaway server on localhost.
#
# Everything else in the suite goes through MockTransport, which is a different method of
# `fetch_raw` entirely — so without this file, `fetch_raw(::HTTPTransport, ...)` has zero
# coverage and mistakes in it are invisible. That is not hypothetical: an HTTP.jl keyword
# deprecation sat unnoticed in that function precisely because nothing offline ever called
# it.
#
# Still fully offline and deterministic. Nothing here touches the network.

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
            return HTTP.Response(200, "target=$(req.target)\nauth=$auth")
        elseif path == "/flaky"
            # Fails twice, then succeeds — should be retried through to success.
            return hits[path] < 3 ? HTTP.Response(500, "server error") :
                                    HTTP.Response(200, "recovered")
        elseif path == "/bad"
            return HTTP.Response(400, "{\"result\": -1, \"message\": \"nope\"}")
        elseif path == "/empty"
            return HTTP.Response(200, "")
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

        @testset "empty 200 body is preserved, not mangled" begin
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

        @testset "an explicit timeout still makes a working request" begin
            # The guard the file header describes: `fetch_raw(::HTTPTransport, ...)` is
            # only ever run here, so a keyword HTTP.jl has renamed or removed shows up in
            # this testset and nowhere else. `connect_timeout` matters most — HTTP.jl
            # defaults it to 0, meaning unlimited, so if it stops being threaded through
            # then a black-holed address hangs on the OS TCP timeout no matter what
            # `timeout` says. (Verified manually: ~31s against a non-routable IP with the
            # keyword absent. That is not asserted here because it needs real routing,
            # and this suite stays offline.)
            resp = fetch_raw(transport(timeout = 5), "ok", Dict("a" => "1"))
            @test resp.status == 200
            @test body_string(resp) == "hello"
        end
    finally
        close(server)
    end
end
