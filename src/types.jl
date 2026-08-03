"""
    GeoLevel

Geographic resolution of an observation. Values are written to disk as plain integers. 
Never renumber an existing entry; append instead, or previously written Arrow files will
silently decode to the wrong level.
"""
@enum GeoLevel::Int8 begin
    NATION          = 0
    HHS_REGION      = 1
    CENSUS_DIVISION = 2
    STATE           = 3
    COUNTY          = 4
    MSA             = 5
    HRR             = 6
    DMA             = 7
    HSA_NCI         = 8
end

"""
    MissingCode

Why a measurement is absent. Codes are Delphi's documented values, so the integers
carry meaning beyond this package and must not be renumbered.

`NOT_MISSING` is the normal case: the value is present. A row can carry a present
`value` and still be missing `stderr`/`sample_size`; this field describes `value`.
"""
@enum MissingCode::Int8 begin
    NOT_MISSING      = 0
    NOT_APPLICABLE   = 1
    REGION_EXCEPTION = 2
    CENSORED         = 3
    DELETED          = 4
    OTHER            = 5
end

"""
    EpiObservation

A measurement of one signal, in one place, over one specific time interval.

The interval is closed, so `period_start:period_end` is inclusive. A daily observation has
`period_start == period_end`; a weekly one spans the MMWR week, Sunday through Saturday.

`issue` refers to the date the observation was issued by the source. Surveillance numbers are often
revised after the fact, so (period_start, issue) is the true identifier for a measurement.

Note that Delphi provides a `lag` field, which we have chosen here not to store.
By definition, `lag = issue - period_end`, so it is redundant and can be derived from the
other fields. Storing it would be one more thing that can disagree with the fields it derives from.
"""
struct EpiObservation
    source::Symbol
    signal::Symbol
    geo_level::GeoLevel
    geo_id::String
    period_start::Date
    period_end::Date
    value::Union{Float64,Missing}
    stderr::Union{Float64,Missing}
    sample_size::Union{Float64,Missing}
    issue::Union{Date,Missing}
    missing_code::MissingCode
end

# --------------------------------------------------
#                   EQUALITY TYPES
# --------------------------------------------------

# `==` on a struct holding `missing` would propagate `missing` rather than answer the
# question, which makes observations hard to compare or deduplicate. These are
# records, so compare them by `isequal` such that `missing` is treated as a value.
# `hash` is kept consistent so observations can be used as Dict keys and in Sets.
Base.:(==)(a::EpiObservation, b::EpiObservation) = isequal(a, b)

Base.isequal(a::EpiObservation, b::EpiObservation) =
    all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(EpiObservation))

Base.hash(o::EpiObservation, h::UInt) =
    foldr((f, acc) -> hash(getfield(o, f), acc), fieldnames(EpiObservation); init = hash(EpiObservation, h))

"""
    EpiTable

A column-oriented collection of [`EpiObservation`](@ref).

This is a `StructArray`, so it stores one vector per field while still indexing as rows
(`tbl[3]` is an `EpiObservation`). The columnar layout is what `Arrow.write` consumes
directly: writing hands over the existing column vectors, where a `Vector{EpiObservation}`
would force Arrow to transpose every row into columns first.

Converts to a `DataFrame` in one call:

    using DataFrames
    df = DataFrame(tbl)                   # copies the columns, as DataFrames defaults to
    df = DataFrame(tbl; copycols = false) # shares them, no allocation

`copycols = false` is worth reaching for on large tables, with the usual caveat that the
two objects then alias the same vectors and mutating one is visible in the other.
"""
const EpiTable = StructArray{EpiObservation}

# --------------------------------------------------
#                   SOURCE TAGS
# --------------------------------------------------

"""
    AbstractSource

Tag identifying which upstream endpoint a payload came from. `standardize` dispatches on
these, so each source can decode its own layout while producing the same [`EpiTable`](@ref).
"""
abstract type AbstractSource end

"""
    DelphiCovidcast()

The Delphi Epidata `covidcast` endpoint: one measurement per row.
"""
struct DelphiCovidcast <: AbstractSource end

# --------------------------------------------------
#                   ERROR TYPES
# --------------------------------------------------

"""
    EpiDataKitError

Supertype for every error this package raises on purpose. Catch this to handle any
failure originating in EpiDataKit rather than in HTTP.jl or CSV.jl.
"""
abstract type EpiDataKitError <: Exception end

"""
    scrub_secrets(s::AbstractString)

Blank out anything credential-shaped in a request description before it is stored on an
exception. Exceptions get logged, printed, and pasted into issue trackers, so a key that
reaches one should be assumed disclosed.

The transport sends the API key as an HTTP Basic header rather than a query parameter, so
this is a second line of defence for hand-built URLs, not the primary one.

The parameter list errs towards over-redaction. None of Delphi's own query parameters
(`data_source`, `signal`, `time_type`, `geo_type`, `time_values`, `geo_value`, `format`,
`as_of`, `issues`, `lag`) contain any of these substrings, so a false positive costs
nothing here while a false negative discloses a credential.
"""
function scrub_secrets(s::AbstractString)
    out = replace(s,
        r"(?i)\b(api[-_]?key|apikey|auth|authorization|access[-_]?token|token|secret|password|passwd|pwd|key)=[^&\s]*"
        => s"\1=[REDACTED]")
    out = replace(out, r"(?i)(https?://)[^/@\s]+:[^/@\s]+@" => s"\1[REDACTED]@")
    # An `Authorization: Basic <base64>` value decodes straight back to the key.
    replace(out, r"(?i)\b(Basic|Bearer)\s+[A-Za-z0-9+/=._~-]+" => s"\1 [REDACTED]")
end

"""
    ValidationError(msg)

A request was rejected before it was sent, because it could not have been valid.
"""
struct ValidationError <: EpiDataKitError
    msg::String
end

"""
    NoResultsError(request)

The query was well-formed and the server understood it, but no data matched.

In CSV mode this arrives as an empty `200` body with no result code at all; in JSON mode
as `result: -2`. Both land here.
"""
struct NoResultsError <: EpiDataKitError
    request::String
    NoResultsError(request) = new(scrub_secrets(request))
end

"""
    TruncatedResultsError(request, message)

The result set hit the server's row cap (`result: 2`), so what came back is a prefix of
the real answer.

This is deliberately an error and not a warning. A truncated response is
indistinguishable from a complete one by inspection, so treating it as success means
silently analysing partial data. Callers that can subdivide the query should catch this
and narrow the time window.
"""
struct TruncatedResultsError <: EpiDataKitError
    request::String
    message::String
    TruncatedResultsError(request, message) = new(scrub_secrets(request), message)
end

"""
    EpidataError(request, code, message)

The server reported a failure in its own error format — a malformed query, an unknown
parameter, or any other `result: -1`.
"""
struct EpidataError <: EpiDataKitError
    request::String
    code::Union{Int,Nothing}
    message::String
    EpidataError(request, code, message) = new(scrub_secrets(request), code, message)
end

"""
    StoreError(path, msg)

A file on disk could not be read back as an [`EpiTable`](@ref): it is not an Arrow file,
it is an Arrow file written by something else, or it carries a schema value this version
of the package does not know.

That last case is the forward-compatibility one. [`GeoLevel`](@ref) and
[`MissingCode`](@ref) are documented as append-only, so a file written by a newer
EpiDataKit can hold a level this build has never heard of. Reading it is a real failure —
guessing would misattribute the row — but it is a failure the message can explain.
"""
struct StoreError <: EpiDataKitError
    path::String
    msg::String
end

"""
    TransportError(request, status, body_excerpt)

The exchange failed below the API's own error protocol: an unexpected status with a body
that is not Epidata's error format at all, such as a 404 HTML page or a proxy error.
"""
struct TransportError <: EpiDataKitError
    request::String
    status::Int
    body_excerpt::String
    TransportError(request, status, body_excerpt) =
        new(scrub_secrets(request), status, first(body_excerpt, 200))
end

Base.showerror(io::IO, e::ValidationError) = print(io, "ValidationError: ", e.msg)

Base.showerror(io::IO, e::NoResultsError) =
    print(io, "NoResultsError: query returned no rows\n  request: ", e.request)

Base.showerror(io::IO, e::TruncatedResultsError) = print(
    io,
    "TruncatedResultsError: result set hit the server row cap, data is incomplete\n",
    "  request: ", e.request, "\n",
    "  server:  ", e.message, "\n",
    "  hint:    narrow the time window and combine the pieces",
)

Base.showerror(io::IO, e::EpidataError) = print(
    io,
    "EpidataError: server reported result=", something(e.code, "unknown"), "\n",
    "  request: ", e.request, "\n",
    "  server:  ", e.message,
)

Base.showerror(io::IO, e::TransportError) = print(
    io,
    "TransportError: HTTP ", e.status, "\n",
    "  request: ", e.request, "\n",
    "  body:    ", e.body_excerpt,
)

Base.showerror(io::IO, e::StoreError) =
    print(io, "StoreError: ", e.msg, "\n  path: ", e.path)
