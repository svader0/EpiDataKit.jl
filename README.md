# EpiDataKit

[![Build Status](https://github.com/svader0/EpiDataKit.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/svader0/EpiDataKit.jl/actions/workflows/CI.yml?query=branch%3Amain)

Fetch public health surveillance data, standardise it into one tidy schema, and persist it
as Arrow that modelling packages can read for almost nothing.

Julia has good epidemic modelling — [EpiAware.jl](https://github.com/CDCgov/Rt-without-renewal),
[Pathogen.jl](https://github.com/jangevaare/Pathogen.jl) — but no way to get real
surveillance data into it. R has [`epidatr`](https://cmu-delphi.github.io/epidatr/) and
Python has [`epidatpy`](https://github.com/cmu-delphi/epidatpy); this is the missing
Julia equivalent.

Not affiliated with or endorced by Carnegie Mellon University or the Delphi Group.

## Install

```julia
julia> ]
pkg> add https://github.com/svader0/EpiDataKit.jl
```

## Quick start

```julia
using EpiDataKit

tbl = fetch_signal(
    data_source = "nssp",
    signal      = "pct_ed_visits_covid",
    time_type   = "week",
    geo_type    = "state",
    time_values = "202620-202629",
    geo_value   = "ca",
)

tbl[1]
# EpiObservation(:nssp, :pct_ed_visits_covid, STATE, "ca",
#                Date("2026-05-17"), Date("2026-05-23"),
#                0.07, missing, missing, Date("2026-08-01"), NOT_MISSING)

EpiDataKit.save(tbl, "nssp_covid.arrow")
tbl2 = EpiDataKit.load("nssp_covid.arrow")
```

Weekly signals accept real dates, so you never have to compute an epiweek by hand:

```julia
tbl = fetch_signal(
    data_source = "nhsn", signal = "confirmed_admissions_covid_ew",
    time_type = "week", geo_type = "state",
    time_values = Date(2026, 1, 1):Date(2026, 6, 1),
    geo_value = "ca",
)
```

Delphi allows 60 requests/hour anonymously and lifts the cap entirely with a
[free API key](https://cmu-delphi.github.io/delphi-epidata/api/api_keys.html). Set
`DELPHI_EPIDATA_KEY` and it is picked up automatically — and sent as an HTTP Basic header,
never as a query parameter, so it cannot leak through logs or an exception message.

## The schema

Everything lands in one flat table, whatever the source or time resolution:

```julia
struct EpiObservation
    source::Symbol
    signal::Symbol
    geo_level::GeoLevel                   # NATION, STATE, COUNTY, MSA, HRR, …
    geo_id::String
    period_start::Date                    # closed interval, inclusive
    period_end::Date                      # == period_start for daily signals
    value::Union{Float64,Missing}
    stderr::Union{Float64,Missing}
    sample_size::Union{Float64,Missing}
    issue::Union{Date,Missing}            # when it was published, not what it describes
    missing_code::MissingCode             # why `value` is absent, when it is
end
```

Two choices worth explaining:

**Intervals, not a resolution flag.** A daily observation is a one-day interval and a
weekly one spans Sunday–Saturday, so daily and weekly signals share a schema without every
consumer having to branch on which it is holding.

**`issue` is kept.** Surveillance numbers get revised after first release, so
`(period_start, issue)` — not `period_start` alone — identifies a measurement. Keeping it
makes as-of reconstruction possible: what did we believe on a given date. Delphi's `lag`
is deliberately dropped, since it is `issue - period_end` by definition and a stored copy
is just something that can drift out of agreement.

The result is a `StructArray`, so it is column-oriented for Arrow but still indexes as
rows. `DataFrames` is not a dependency — a modelling package that only wants to read an
Arrow file should not pay for its load time — but the conversion is tested:

```julia
using DataFrames
df = DataFrame(tbl)                   # copies columns (DataFrames' default)
df = DataFrame(tbl; copycols = false) # shares them, no allocation
```

## Storage

Reproduce with `julia --project=bench bench/size_and_reload.jl`. Numbers below are from
500,000 rows of synthetic data with realistic cardinality, on one machine — treat the
ratios as the durable part, not the absolute times.

| | JSON | Arrow + zstd | Arrow, uncompressed |
|---|---|---|---|
| file size | 109.6 MiB | **9.5 MiB** (11.5×) | 20.3 MiB (5.4×) |
| open + scan a column | 1828 ms | 30.1 ms | **0.841 ms** |
| allocations | 1437 MiB | 20.3 MiB | **0.04 MiB** |

**Compression is off by default**, which looks like the wrong call until you notice the
last two rows. Compression and zero-copy mmap are mutually exclusive: a zstd file has to
decompress every buffer into fresh memory when opened, which is why it reads 36× slower
and allocates 463× more than the uncompressed file the OS can simply map. A cache exists
to be read repeatedly, so it should be the fast one — and uncompressed Arrow is still 5.4×
smaller than the JSON it came from. Pass `compress = :zstd` for archival copies.

**Those read numbers are `Arrow.Table(path)`, not `EpiDataKit.load`.** `load` copies every
column into an ordinary Julia vector, which is what makes the returned table's element type
exactly `EpiObservation` and `load(save(x)) == x` hold — so it does not inherit the mapping
benefit:

| reading the same uncompressed file | time | allocations |
|---|---|---|
| `Arrow.Table(path)` + scan a column | 0.841 ms | 0.04 MiB |
| `EpiDataKit.load(path)` + scan a column | 68.6 ms | 52.5 MiB |

Use `load` when you want the schema and exact round-trip equality; open the file with
`Arrow.Table` directly when you are scanning a large cache and want the mmap.

**Dictionary encoding is applied per column, not globally.** `Arrow.write(...;
dictencode = true)` builds a dictionary for *every* column, including the high-entropy
floats where it is pure overhead. Encoding only the columns that actually repeat is
meaningfully better:

| zstd write strategy | size |
|---|---|
| no dictionary encoding | 14.7 MiB |
| `dictencode = true` (every column) | 12.7 MiB |
| selective `DictEncode` | **9.5 MiB** |

The output is readable by anything that speaks Arrow, without knowing this package exists.

`GeoLevel` and `MissingCode` are registered with `ArrowTypes` as `Int8` and deliberately
*not* given an extension name, so they carry no Julia-specific metadata and arrive as
ordinary integers. (They are dictionary-encoded, so the schema reports
`dictionary<values=int8>`; the values decode to `int8` either way.) The `Symbol` and `Date`
columns do carry `JuliaLang.*` extension annotations, which foreign readers ignore, falling
back to the underlying `utf8` and `date32`.

Verify a file yourself with the checker in `test/portability_check/`:

```bash
go -C test/portability_check run . "$PWD/nssp_covid.arrow"
```

```
  geo_level      dictionary<values=int8, indices=int8, ordered=false>
  geo_id         dictionary<values=utf8, indices=int8, ordered=false>
  period_start   date32                                             [JuliaLang.Date]
  ...
OK: enum columns are plain integers with no Julia-specific metadata.
```

It is written in Go against [arrow-go](https://github.com/apache/arrow-go) on purpose.
arrow-go is an independent native implementation of the format rather than a binding to
the same C++ library, so agreement between it and Arrow.jl is real evidence of
portability, where agreement between two wrappers around shared code would prove less.
The absolute path is needed because `go -C` runs the tool from its own module directory.

## Notes from the wire

A couple of things the documentation does not tell you, measured against the live API:

**Error signalling depends on the response format.** The common advice — "Delphi returns
errors with HTTP 200, so trust `result` and ignore the status" — is true only in JSON
mode. This package requests CSV, where:

| case | status | body |
|---|---|---|
| success | 200 | 15-column CSV |
| no results | 200 | **empty** — zero bytes, no result code at all |
| invalid parameter | **400** | JSON `{"result": -1, …}`, despite `format=csv` |
| unknown endpoint | 404 | HTML |

All of it funnels through one `decode_response`, and every branch is pinned by a recorded
fixture in `test/fixtures/`.

**`result: 2` means truncation, and is treated as an error.** A capped result set is
indistinguishable from a complete one by inspection, so returning it as success would mean
silently analysing partial data. It raises `TruncatedResultsError` instead.

**MMWR epiweeks are not ISO weeks shifted by a day.** That shortcut disagrees with the
real definition whenever Dec 31 falls on a Wednesday — it maps 2025-12-31 to `(2026, 1)`
where the answer is `(2025, 53)`. The implementation computes them directly and is checked
against the published anchors, an exhaustive round-trip over 2010–2035, and the known
53-week years.

## Scope

Working now: the `covidcast` endpoint end to end — fetch, retry with backoff, standardise,
Arrow round-trip — with an offline test suite.

Not yet: rate limiter, concurrent chunked fetch, `covidcast_meta` catalog validation, the
`fluview` endpoint, and an incremental on-disk cache.

## Citation

This package only retrieves data; it does not produce any. Cite the source you actually
pulled from as well, and check its licence — terms vary by signal, and some prohibit
commercial use. For Delphi, see their
[citation](https://cmu-delphi.github.io/delphi-epidata/api/covidcast.html) and
[licensing](https://cmu-delphi.github.io/delphi-epidata/api/covidcast_licensing.html) pages.

However, if how you obtained and standardized your data is itself relevant, please cite this
software as follows:

```bibtex
@software{epidatakit,
  title   = {EpiDataKit.jl: Surveillance data ingestion for Julia},
  author  = {Vader, Sam},
  year    = {2026},
  version = {0.1.0},
  url     = {https://github.com/svader0/EpiDataKit.jl}
}
```

Cite the version you actually used. GitHub's "Cite this repository" button generates this
from [`CITATION.cff`](CITATION.cff) in other formats too.


## Development

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The test suite never touches the network. Requests are served by a `MockTransport` reading
recorded fixtures, and the real HTTP path is exercised against a throwaway server on
localhost, so everything is offline and deterministic.

Checking that Delphi still behaves the way `test/fixtures/` records is a separate concern
with a different meaning — a red test should mean *our* code is wrong, not that someone
else's server moved. That lives in a script you run deliberately:

```bash
julia --project=. scripts/check_upstream.jl           # report drift
julia --project=. scripts/check_upstream.jl --write   # re-record the fixtures
```

It verifies the response *shape* rather than diffing bytes: the CSV header, the status
codes, and how each failure mode is signalled. The measurement values themselves change
whenever Delphi revises them, so a byte-exact comparison would report drift constantly.
Run it when touching `src/sources/`, or before tagging a release.
