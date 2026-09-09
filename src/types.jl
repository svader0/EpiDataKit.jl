"""
    GeoLevel

Geographic resolution of an observation. Values are written to disk as plain integers. 
Never renumber an existing entry; append instead, or previously written Arrow files will
decode to the wrong level.
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
    CENSUS_REGION   = 9
    SEWERSHED       = 10
    VA_FACILITY     = 11
end

"""
    MissingCode

Why a measurement is absent. Codes are Delphi's documented values, so the integers
carry meaning beyond this package and must not be renumbered.

`NOT_MISSING` is the normal case, i.e the value is present.
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

`lag` is how long after the period the value was published, counted in the signal's own
time units: days for a daily signal, weeks for a weekly one. It is stored as the source
reported it rather than recomputed. `issue - period_end` gives days regardless, and this
schema does not record the time resolution, so deriving `lag` would mean inferring it from
the interval width and then converting. Nowcast evaluation filters on lag directly, so it
is worth a column.

`fill_method` records how nulls were handled during geographic aggregation, which the V5
API treats as part of a row's identity: `:source` means the value came straight from the
publisher with no aggregation, `:ave` means nulls were filled with a neighbour average,
and `:zero` means they were filled with zero. V3 and V4 rows are always `:source`.

`ci_lower` and `ci_upper` bound a confidence interval. V5 reports uncertainty this way for
some sources, where V3 and V4 reported `stderr` and `sample_size`. A row carries one pair
or the other, never both.
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
    ci_lower::Union{Float64,Missing}
    ci_upper::Union{Float64,Missing}
    issue::Union{Date,Missing}
    lag::Union{Int,Missing}
    fill_method::Symbol
    missing_code::MissingCode
end

EpiObservation(; source, signal, geo_level, geo_id, period_start, period_end,
                 value = missing, stderr = missing, sample_size = missing,
                 ci_lower = missing, ci_upper = missing, issue = missing,
                 lag = missing, fill_method = :source, missing_code = NOT_MISSING) =
    EpiObservation(source, signal, geo_level, geo_id, period_start, period_end,
                   value, stderr, sample_size, ci_lower, ci_upper, issue, lag,
                   fill_method, missing_code)

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

As a `StructArray`, it stores one vector per field while still indexing as rows. 
The columnar layout is what `Arrow.write` consumes directly, which makes things
very efficient for us.

It also converts to a `DataFrame` in one line:

    using DataFrames
    df = DataFrame(tbl)                   # copies the columns, as DataFrames defaults to
    df = DataFrame(tbl; copycols = false) # shares them, no allocation

`copycols = false` is worth reaching for on large tables, with the obvious caveat that 
mutating one is visible in the other.
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

"""
    DelphiFluView()

The Delphi Epidata `fluview` endpoint: influenza-like illness from CDC's outpatient
network. One row carries several measurements, so standardizing fans it out into one
observation per measurement.
"""
struct DelphiFluView <: AbstractSource end

"""
    DelphiCovidcastMeta()

The Delphi Epidata `covidcast_meta` endpoint: one row per signal and geographic level,
describing coverage rather than measurements. Read by [`catalog`](@ref).
"""
struct DelphiCovidcastMeta <: AbstractSource end

"""
    DelphiV5(source)

A source served by the Epidata V5 API, named by its V5 `source` parameter, such as
`DelphiV5(:nssp)`.

V5 responses carry no `source` column, because the source is a request parameter. The tag
therefore has to carry it so [`standardize`](@ref) can put it back on every row.
"""
struct DelphiV5 <: AbstractSource
    source::Symbol
end

# --------------------------------------------------
#                   CATALOG SCHEMA
# --------------------------------------------------

"""
    CatalogEntry

One dataset you can fetch: a signal, at one time resolution, at one geographic level.

`first_period` and `last_period` bound the data that exists, on the same closed-interval
convention [`EpiObservation`](@ref) uses. `last_issue` is the most recent vintage published.
`fetch_with` names the function that retrieves it.

The extent columns admit `missing` because not every endpoint publishes them. `fluview`
reports one summary row for its whole table rather than per-signal coverage, so its entries
carry the signal, the resolution, and the level, and nothing else. V5 entries leave
`time_type` `missing` too: the V5 `metadata/` endpoint reports no time resolution, and
`reference_time` is a plain calendar date either way.
"""
struct CatalogEntry
    source::Symbol
    signal::Symbol
    time_type::Union{Symbol,Missing}
    geo_level::GeoLevel
    first_period::Union{Date,Missing}
    last_period::Union{Date,Missing}
    num_locations::Union{Int,Missing}
    last_issue::Union{Date,Missing}
    min_lag::Union{Int,Missing}
    max_lag::Union{Int,Missing}
    fetch_with::Symbol
end

"""
    CatalogTable

A column-oriented collection of [`CatalogEntry`](@ref), built by [`catalog`](@ref).

Like [`EpiTable`](@ref) it is a `StructArray` and so a Tables.jl source, which is what makes
`DataFrame(cat)` and `unique(cat.source)` both work. It is not an `EpiTable` and does not
describe observations, so [`save`](@ref) and [`load`](@ref) do not apply to it.
"""
const CatalogTable = StructArray{CatalogEntry}

# --------------------------------------------------
#                   ERROR TYPES
# --------------------------------------------------

"""
    EpiDataKitError

For every error this package raises on purpose. Catch this to handle any
failure originating in EpiDataKit rather than in HTTP.jl or CSV.jl or whathaveyou.
"""
abstract type EpiDataKitError <: Exception end

"""
    scrub_secrets(s::AbstractString)

Blank out anything credential-shaped in a request description before it is stored on an
exception. Exceptions get logged, printed, and pasted into issue trackers, so a key that
reaches one should be assumed disclosed.

The transport sends the API key as an HTTP Basic header rather than a query parameter, so
this is a second line of defense.
"""
function scrub_secrets(s::AbstractString)
    out = replace(s,
        r"(?i)\b(api[-_]?key|apikey|auth|authorization|access[-_]?token|token|secret|password|passwd|pwd|key)=[^&\s]*"
        => s"\1=[REDACTED]")
    out = replace(out, r"(?i)(https?://)[^/@\s]+:[^/@\s]+@" => s"\1[REDACTED]@")
    # An `Authorization: Basic <base64>` value decodes straight back to the key.
    out = replace(out, r"(?i)\b(Basic|Bearer)\s+[A-Za-z0-9+/=._~-]+" => s"\1 [REDACTED]")
    replace(out, r"(?i)\btoken:\s*[A-Za-z0-9+/=._~-]+" => s"token: [REDACTED]")
end

"""
    ValidationError(msg)

A request was rejected before it was sent because it was malformed or nonsensical.
"""
struct ValidationError <: EpiDataKitError
    msg::String
end

"""
    NoResultsError(request)

The query was well-formed and the server understood it, but no data matched.

In CSV mode this arrives as an empty `200` body with no result code at all.
"""
struct NoResultsError <: EpiDataKitError
    request::String
    NoResultsError(request) = new(scrub_secrets(request))
end

"""
    TruncatedResultsError(request, message)

The result set hit the server's row cap, so what came back is a prefix of
the real answer. An incomplete result is worse than no result, so this is an 
error rather than a warning.
"""
struct TruncatedResultsError <: EpiDataKitError
    request::String
    message::String
    TruncatedResultsError(request, message) = new(scrub_secrets(request), message)
end

"""
    EpidataError(request, code, message)

The server reported a failure in its own error format. Either it is a malformed query, an unknown
parameter, or any other problem.
"""
struct EpidataError <: EpiDataKitError
    request::String
    code::Union{Int,Nothing}
    message::String
    EpidataError(request, code, message) = new(scrub_secrets(request), code, message)
end

"""
    StoreError(path, msg)

A file on disk could not be read back as an [`EpiTable`](@ref). Either it is not an Arrow file,
it is an Arrow file written by something else, or it carries a schema value this version
of the package does not know.
"""
struct StoreError <: EpiDataKitError
    path::String
    msg::String
end

"""
    TransportError(request, status, body_excerpt)

The exchange failed below the API's own error protocol: an unexpected status with a body
that is not Epidata's error format at all.
"""
struct TransportError <: EpiDataKitError
    request::String
    status::Int
    body_excerpt::String
    TransportError(request, status, body_excerpt) =
        new(scrub_secrets(request), status, first(body_excerpt, 200))
end

# Error type show-ers:

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
