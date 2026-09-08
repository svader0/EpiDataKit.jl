# Measured against the live V5 API on 2026-09-08. See
# docs/superpowers/specs/2026-09-08-epidata-v5.md for the full record.
#
#   success             200  text/csv, key header + value columns + rows
#   no rows             200  *header line only*. How an unknown signal, an unknown
#                            geo_type, and a comma separated signal list all answer
#   bad parameter       422  JSON {"detail": [{"type", "loc", "msg", "input"}]}
#   unknown endpoint    404  HTML
#
# There is no `result` code anywhere and no truncation code. Two of the failure modes are
# silent 200s, which is why v5_params validates locally before sending.

"""
The first six columns of every V5 CSV response, in order. The value columns that follow
vary by source, so this is a prefix check rather than an equality check.
"""
const V5_KEY_HEADER = "signal,report_time,geo_type,geo_value,fill_method,reference_time"

"""
    v5_error_message(body) -> Union{String,Nothing}

Render FastAPI's `detail` array into one line, or return `nothing` for a body that is not
one.
"""
function v5_error_message(body::AbstractString)
    startswith(lstrip(body), '{') || return nothing
    obj = try
        JSON3.read(body)
    catch
        return nothing
    end
    (obj isa JSON3.Object && haskey(obj, :detail)) || return nothing
    detail = obj.detail
    detail isa JSON3.Array || return string(detail)

    parts = String[]
    for d in detail
        loc = haskey(d, :loc) ? join(string.(d.loc), ".") : ""
        msg = haskey(d, :msg) ? string(d.msg) : ""
        push!(parts, isempty(loc) ? msg : string(loc, ": ", msg))
    end
    return join(parts, "; ")
end

"""
    decode_v5(resp::EpiResponse) -> Tables.jl source

Turn a raw V5 response into something tabular, or throw the most specific error that fits.

A body holding only the header line is [`NoResultsError`](@ref): that is how V5 reports an
unknown signal or geo_type, both at status 200.
"""
function decode_v5(resp::EpiResponse)
    body = body_string(resp)
    stripped = strip(body)

    # V4 used an empty body for "no rows". V5 always sends the header, so an empty body
    # here means the response was cut short.
    isempty(stripped) && throw(TransportError(resp.request, resp.status, ""))

    msg = v5_error_message(stripped)
    msg === nothing || throw(EpidataError(resp.request, resp.status, msg))

    200 <= resp.status < 300 ||
        throw(TransportError(resp.request, resp.status, stripped))

    startswith(stripped, V5_KEY_HEADER) || throw(EpidataError(resp.request, nothing,
        "unrecognized 200 body: it does not begin with the V5 key header " *
        repr(V5_KEY_HEADER) * ". First 200 bytes: " * first(stripped, 200)))

    occursin('\n', stripped) || throw(NoResultsError(resp.request))

    # `geo_value` is forced to String because CSV parsing would otherwise read a county
    # FIPS code such as "06075" as the integer 6075 and lose the leading zero.
    return CSV.File(resp.body; types = Dict("geo_value" => String), stringtype = String,
                    validate = false)
end
