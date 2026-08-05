# Nothing above this layer touches HTTP.jl; it sees only `EpiResponse`. That is what lets
# the suite run offline against `MockTransport`, which is how the error paths get tested at
# all; they are the ones hardest to trigger on demand against a live API.

"""
    RateLimitInfo

What the server said about your remaining quota, when it said anything.

Delphi is load-balanced and only some nodes emit the `x-my-*` headers, so every field is
optional and an all-`nothing` value is normal rather than an error. Callers should treat
this as a hint that lets them be more precise, never as a guarantee.

`retry_after` is populated whenever the header is present, but note that Delphi sends it
on ordinary `200` responses too; it is only meaningful alongside a `429` or `503`.
"""
struct RateLimitInfo
    limit::Union{Int,Nothing}
    remaining::Union{Int,Nothing}
    reset::Union{DateTime,Nothing}
    retry_after::Union{Int,Nothing}
end

"""
    EpiResponse

A transport-agnostic HTTP response: status, raw body, lowercased headers, and a scrubbed
description of the request that produced it (used for error messages).
"""
struct EpiResponse
    status::Int
    body::Vector{UInt8}
    headers::Dict{String,String}
    request::String
end

body_string(r::EpiResponse) = String(copy(r.body))

_parse_int(s) = s === nothing ? nothing : tryparse(Int, strip(s))

"""
    ratelimit(r::EpiResponse) -> RateLimitInfo

Extract Delphi's quota headers, if this particular server bothered to send them.
"""
function ratelimit(r::EpiResponse)
    reset_raw = _parse_int(get(r.headers, "x-my-reset", nothing))
    RateLimitInfo(
        _parse_int(get(r.headers, "x-my-limit", nothing)),
        _parse_int(get(r.headers, "x-my-remaining", nothing)),
        reset_raw === nothing ? nothing : unix2datetime(reset_raw),
        _parse_int(get(r.headers, "retry-after", nothing)),
    )
end

"""
    canonical_query(params) -> String

Render query parameters in a stable order.

Sorting matters for more than tidiness: `MockTransport` keys its fixtures on this string,
so without a canonical ordering an identical request would miss the fixture depending on
`Dict` iteration order.
"""
function canonical_query(params)
    pairs = sort!([(string(k), string(v)) for (k, v) in params]; by = first)
    join(("$(HTTP.escapeuri(k))=$(HTTP.escapeuri(v))" for (k, v) in pairs), "&")
end

"""
    request_key(endpoint, params) -> String

The canonical identity of a request: what fixtures are keyed on and what error messages
report. Contains no credentials: the API key travels in a header, never here.
"""
request_key(endpoint::AbstractString, params) = string(endpoint, "?", canonical_query(params))

"""
    AbstractTransport

How a request actually gets made. Implement `fetch_raw(::T, endpoint, params)` returning
an [`EpiResponse`](@ref).
"""
abstract type AbstractTransport end

const DELPHI_BASE_URL = "https://api.delphi.cmu.edu/epidata/"

"""
    HTTPTransport(; base_url, api_key, max_retries, base_delay, max_delay, timeout)

Talks to the real API.

The API key defaults to `ENV["DELPHI_EPIDATA_KEY"]` and is sent as HTTP Basic auth
(`epidata:<key>`) rather than as a query parameter, so it cannot leak through access
logs, `Referer` headers, or an exception that quotes the URL.

Retries cover `429` and `5xx` only. A `4xx` means the request itself was wrong and will
be exactly as wrong the second time, so retrying it just burns quota that is capped at
60 requests/hour for anonymous callers.

`timeout` bounds the connect and the response phases separately, so one attempt can take
up to roughly twice it; `max_retries` multiplies that again.

`max_response_bytes` caps the decompressed response. HTTP.jl's own default is 64 MiB, below
what ordinary epidemiological queries return: all US counties, daily, over 2020-2021 is a
few hundred MiB of CSV. The default here is raised to suit that while staying bounded, so a
runaway response cannot exhaust memory in a long-running process. Note that it only applies
to responses that arrive compressed, which is what Delphi sends.
"""
struct HTTPTransport <: AbstractTransport
    base_url::String
    api_key::Union{String,Nothing}
    max_retries::Int
    base_delay::Float64
    max_delay::Float64
    timeout::Int
    max_response_bytes::Int
end

function HTTPTransport(;
    base_url::AbstractString = DELPHI_BASE_URL,
    api_key::Union{AbstractString,Nothing} = get(ENV, "DELPHI_EPIDATA_KEY", nothing),
    max_retries::Integer = 3,
    base_delay::Real = 1.0,
    max_delay::Real = 30.0,
    timeout::Integer = 60,
    max_response_bytes::Integer = 512 * 1024 * 1024,
)
    key = api_key === nothing || isempty(api_key) ? nothing : string(api_key)
    HTTPTransport(string(base_url), key, Int(max_retries), Float64(base_delay),
                  Float64(max_delay), Int(timeout), Int(max_response_bytes))
end

function auth_headers(t::HTTPTransport)
    t.api_key === nothing && return Pair{String,String}[]
    token = base64encode(string("epidata:", t.api_key))
    return ["Authorization" => string("Basic ", token)]
end

_headers_dict(h) = Dict{String,String}(lowercase(string(k)) => string(v) for (k, v) in h)

"""
    backoff_delay(t, attempt, retry_after) -> Float64

Seconds to wait before retry number `attempt`.

An explicit `Retry-After` wins outright: the server knows when its own window resets, and
guessing shorter just earns another rejection. Otherwise back off exponentially with
jitter in `[0.5, 1.5]×`, so that concurrent workers that were throttled together do not
all wake at the same instant and collide again.
"""
function backoff_delay(t::HTTPTransport, attempt::Integer, retry_after::Union{Int,Nothing})
    retry_after !== nothing && return Float64(min(retry_after, t.max_delay))
    base = min(t.base_delay * 2.0^(attempt - 1), t.max_delay)
    return base * (0.5 + rand())
end

is_retryable(status::Integer) = status == 429 || status >= 500

# A caller only ever sees the decoded table, so without this the anonymous 60/hour limit is
# invisible until it becomes a 429 mid-analysis.
const LOW_QUOTA = 10

function _warn_low_quota(resp::EpiResponse)
    rem = ratelimit(resp).remaining
    (rem === nothing || rem > LOW_QUOTA) && return nothing
    @warn "Delphi API quota nearly exhausted" remaining = rem maxlog = 1
    return nothing
end

function fetch_raw(t::HTTPTransport, endpoint::AbstractString, params)
    key = request_key(endpoint, params)
    url = string(rstrip(t.base_url, '/'), "/", lstrip(endpoint, '/'))
    headers = auth_headers(t)
    local last_resp::Union{EpiResponse,Nothing} = nothing

    for attempt in 1:(t.max_retries + 1)
        resp = try
            # Both phases need a bound. `read_idle_timeout` covers the response, but
            # HTTP.jl defaults `connect_timeout` to 0, meaning no limit, so a black-holed
            # address then hangs on the OS TCP timeout (measured: ~31s against a
            # non-routable IP, regardless of what `timeout` was set to).
            r = HTTP.get(url; query = params, headers = headers,
                         connect_timeout = t.timeout,
                         read_idle_timeout = t.timeout,
                         max_decompressed_size = t.max_response_bytes,
                         status_exception = false, retry = false)
            EpiResponse(r.status, Vector{UInt8}(r.body), _headers_dict(r.headers), key)
        catch e
            e isa InterruptException && rethrow()
            # An oversized response will be exactly as oversized next time, and each retry
            # re-downloads it. HTTP.jl's own message names only its internal keyword, which
            # tells a caller nothing about the query they wrote.
            if e isa HTTP.DecompressionLimitError
                throw(TransportError(key, 0,
                    "response exceeded max_response_bytes = $(t.max_response_bytes). " *
                    "Narrow the query to a shorter time range or fewer geographies, or " *
                    "raise the cap on HTTPTransport."))
            end
            # Connection-level failures (DNS, TLS, timeout) never reach a status code.
            # They are retryable in the same way a 5xx is; re-throw once retries run out.
            attempt > t.max_retries && throw(TransportError(key, 0, sprint(showerror, e)))
            sleep(backoff_delay(t, attempt, nothing))
            continue
        end

        last_resp = resp
        if is_retryable(resp.status) && attempt <= t.max_retries
            sleep(backoff_delay(t, attempt, ratelimit(resp).retry_after))
            continue
        end
        _warn_low_quota(resp)
        return resp
    end

    return last_resp::EpiResponse
end

"""
    MockTransport(fixtures; strict = true)

Serves recorded responses instead of making requests.

`fixtures` maps a [`request_key`](@ref) to an [`EpiResponse`](@ref). Every request is
appended to `calls`, so a test can assert not just what came back but what was actually
sent, including that the API key never appears in the query string.

An unknown key throws rather than returning empty. A test that quietly received "no data"
because of a typo in its own fixture key would pass for the wrong reason.
"""
struct MockTransport <: AbstractTransport
    fixtures::Dict{String,EpiResponse}
    calls::Vector{String}
end

MockTransport(fixtures::AbstractDict) =
    MockTransport(Dict{String,EpiResponse}(fixtures), String[])
MockTransport() = MockTransport(Dict{String,EpiResponse}())

function fetch_raw(t::MockTransport, endpoint::AbstractString, params)
    key = request_key(endpoint, params)
    push!(t.calls, key)
    resp = get(t.fixtures, key, nothing)
    resp === nothing && throw(ValidationError(
        "no fixture for $(repr(key)); recorded fixtures:\n  " *
        join(sort!(collect(keys(t.fixtures))), "\n  ")))
    return resp
end

"""
    mock_response(body; status = 200, headers = Dict(), request = "mock")

Build an [`EpiResponse`](@ref) for tests without going through HTTP.jl.
"""
mock_response(body::AbstractString; status::Integer = 200,
              headers::AbstractDict = Dict{String,String}(), request = "mock") =
    EpiResponse(Int(status), Vector{UInt8}(codeunits(body)),
                Dict{String,String}(lowercase(string(k)) => string(v) for (k, v) in headers),
                string(request))
