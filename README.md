# EpiDataKit

[![Build Status](https://github.com/svader0/EpiDataKit.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/svader0/EpiDataKit.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.21848579.svg)](https://doi.org/10.5281/zenodo.21848579)

EpiDataKit is a Julia package that streamlines the collection, standardization, and use of data from the Delphi Epidata API. It provides a simple interface to the API, including functions for downloading data, parsing results, and converting them into a tidy table. The Epidata API provides access to epidemiological surveillance data for influenza, COVID-19, and other diseases, drawn from government sources such as the CDC, private partners, public datasets, etc. It is maintained by Carnegie Mellon University's Delphi Research Group. 

Observations are returned in a single standardized schema and, if desired, can be written to disk in Apache Arrow format for extremely efficient access across sessions.

There are already official packages for [R](https://cmu-delphi.github.io/epidatr/) and [Python](https://github.com/cmu-delphi/epidatpy), but this is meant to be an alternative for Julia. There is already an impressive modeling ecosystem in Julia, but nobody wants to have to round-trip their data through another language to get it.


Not affiliated with or endorsed by Carnegie Mellon University or the Delphi Group.

## Install

```julia
julia> ]
pkg> add https://github.com/svader0/EpiDataKit.jl
```

## Quick Start

```julia
using EpiDataKit

tbl = fetch_covidcast(
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

# Save table to disk
EpiDataKit.save(tbl, "nssp_covid.arrow")
tbl2 = EpiDataKit.load("nssp_covid.arrow")
```

The table is a Tables.jl source, so it goes straight into a `DataFrame` when you want one:

```julia
using DataFrames

df = DataFrame(tbl; copycols=false)
# 2×11 DataFrame
#  Row │ source  signal               geo_level  geo_id  period_start  period_end  v ⋯
#      │ Symbol  Symbol               GeoLevel   String  Dates.Date    Dates.Date  F ⋯
# ─────┼──────────────────────────────────────────────────────────────────────────────
#    1 │ nssp    pct_ed_visits_covid  STATE      ca      2026-05-17    2026-05-23    ⋯
#    2 │ nssp    pct_ed_visits_covid  STATE      ca      2026-05-24    2026-05-30    ⋯
#                                                                    5 columns omitted
```

Weekly signals accept real dates, so you never have to compute an epiweek by hand:

```julia
tbl = fetch_covidcast(
    data_source = "nhsn", signal = "confirmed_admissions_covid_ew",
    time_type = "week", geo_type = "state",
    time_values = Date(2026, 1, 1):Date(2026, 6, 1),
    geo_value = "ca",
)
```

You can grab multiple signals with one request:

```julia
tbl = fetch_covidcast(
    data_source = "nssp", signal = "pct_ed_visits_covid,pct_ed_visits_influenza",
    time_type = "week", geo_type = "state",
    time_values = "202620-202629", geo_value = "ca",
)
```

### Influenza-like Illness

`fetch_fluview` covers CDC's outpatient ILI network. It takes epiweeks and region codes —
`nat`, `hhs1`–`hhs10`, `cen1`–`cen9`, or state abbreviations:

```julia
flu = fetch_fluview(
    epiweeks = Date(2020, 1, 1):Date(2020, 6, 1),
    regions  = ["nat", "hhs1"],
)

unique(flu.signal)
# [:wili, :ili, :num_ili, :num_patients, :num_providers, :num_age_0, …]
```

FluView reports several measurements per region-week, and the schema holds one value per
row, so each upstream row becomes several observations distinguished by `signal`. For
`wili` and `ili` — percentages — `sample_size` carries `num_patients`, the denominator they
are computed from.

Both endpoints produce the same schema, so results combine without special-casing:

```julia
all = vcat(tbl, flu)
EpiDataKit.save(all, "combined.arrow")
```

### Discovering datasets

`catalog` lists what you can fetch, so signal names do not have to come from Delphi's
website:

```julia
cat = catalog()
length(cat)
# 3014

covid = filter(e -> e.source === :nssp && e.signal === :pct_ed_visits_covid, cat)
covid[1]
# CatalogEntry(:nssp, :pct_ed_visits_covid, :week, COUNTY,
#              Date("2022-09-25"), Date("2026-08-15"), 2426,
#              Date("2026-08-22"), 1, 203, :fetch_covidcast)

sources = unique(cat.source)
length(sources)
# 27

print(filter(in((:nssp, :chng, :fluview)), sources))
# [:chng, :nssp, :fluview]
```

Each entry is one signal at one time resolution and one geographic level, with the extent of
the data and the function that fetches it. It is a Tables.jl source like `EpiTable`, so
filtering and `DataFrame` conversion both work:

```julia
filter(e -> e.source === :nssp && e.geo_level == STATE, cat)
```

Keywords narrow it, and `source` makes the request much smaller:

```julia
catalog(source = "nssp")
catalog(source = "nssp", signal = "pct_ed_visits_covid")
catalog(time_type = "week", geo_type = "county")
```

One call is one request, and the unfiltered reply is about 400 KB, so bind the result
instead of calling it in a loop.

The `fluview` entries are the exception to the coverage columns. The API publishes only a
whole-table summary for that endpoint, not per-signal extents, so those rows carry the
signal, the resolution, and the level, and leave the rest `missing`.

### Data Revisions

`as_of` reconstructs what was known on a given date,
which makes backtesting convenient.

```julia
past = fetch_covidcast(
    data_source = "nssp", signal = "pct_ed_visits_covid",
    time_type = "week", geo_type = "state",
    time_values = "202620", geo_value = "ca",
    as_of = "202625",
)

past.issue    # [Date("2026-06-27")]  — the vintage you asked for
```

### API Access

Delphi allows 60 requests/hour anonymously and lifts the cap entirely with a
[free API key](https://cmu-delphi.github.io/delphi-epidata/api/api_keys.html). Set
`DELPHI_EPIDATA_KEY` and it is picked up automatically — and sent as an HTTP Basic header,
never as a query parameter, so it cannot leak through logs or an exception message.

It is highly recommended to request an API key from Delphi, as you are optionally able to provide data that helps them with future research and funding. 

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
    issue::Union{Date,Missing}            # when it was published
    lag::Union{Int,Missing}               # periods between period_end and issue
    missing_code::MissingCode             # why `value` is absent, when it is
end
```

`lag` is counted in the signal's own time units — days for a daily signal, weeks for a
weekly one — and stored as the source reported it. `issue - period_end` gives days either
way, and the schema deliberately does not record the time resolution, so a derived lag
would be seven times off for weekly signals with nothing to signal the mistake.


The schema uses intervals, not a resolution flag. A daily observation is a one-day interval and a
weekly one spans Sunday–Saturday, so daily and weekly signals share a schema.

Stored as a `StructArray`, so it is column-oriented but still indexes as
rows. `DataFrames` is not a dependency of this package to reduce bloat and load time, but conversion
is direct and tested, and you can choose whether or not to copy.

```julia
using DataFrames

df = DataFrame(tbl)                   # copies columns (DataFrames' default)
df = DataFrame(tbl; copycols = false) # shares them, no allocation
```

## Storage Methodology

We have provided a storage benchmark. Reproduce with `make bench`. Numbers
below are from 500,000 rows of synthetic data with realistic cardinality, on one machine.

| | JSON | Arrow + zstd | Arrow, uncompressed |
|---|---|---|---|
| file size | 109.6 MiB | **9.5 MiB** (11.5×) | 20.3 MiB (5.4×) |
| open + scan a column | 1923 ms | 30.4 ms | **0.84 ms** |
| allocations | 1437 MiB | 20.3 MiB | **0.05 MiB** |

Note that compression is off by default. A zstd file has to decompress every buffer into fresh memory when opened, which is why it reads and allocates so much slower than the uncompressed file. Pass `compress = :zstd` for archival copies.

### `scan` or `load`

Two ways to read a file back:

| | time | allocations | |
|---|---|---|---|
| `EpiDataKit.scan(path)` | 0.85 ms | 0.05 MiB | memory-mapped, read-only |
| `EpiDataKit.load(path)` | 69.4 ms | 52.5 MiB | plain mutable `Vector`s |

Both return an `EpiTable` whose element type is `EpiObservation`. `scan` maps the file and decodes columns on access, so opening costs
the same as `Arrow.Table` on the same file.

Reach for `load` when you intend to modify the table, or when it must outlive the file.

## Scope

Working now: the `covidcast` and `fluview` endpoints end to end — fetch, retry with
backoff, standardize, Arrow round-trip — plus `catalog` for discovering what is available,
all with an offline test suite.

Not yet: `catalog` does not cache, so each call costs a request, and `fetch_covidcast` does
not check a signal name against it before sending. Also absent: a rate limiter, concurrent
chunked fetch, and an incremental on-disk cache.

## Citation

This package only retrieves data; it does not produce any. Cite the source you actually
pulled from as well, and check its license. Terms vary by signal, and some prohibit
commercial use. For Delphi, see their
[citation](https://cmu-delphi.github.io/delphi-epidata/api/covidcast.html) and
[licensing](https://cmu-delphi.github.io/delphi-epidata/api/covidcast_licensing.html) pages.

If how you obtained and standardized your data is itself relevant, please cite this
software as follows:

```bibtex
@software{epidatakit,
  title   = {EpiDataKit.jl: Retrieval and standardization of epidemiological surveillance data in Julia},
  author  = {Vader, Sam},
  year    = {2026},
  version = {0.1.0},
  doi     = {10.5281/zenodo.21848579},
  url     = {https://github.com/svader0/EpiDataKit.jl}
}
```

That DOI resolves to whichever release is newest. To pin a specific one, take the version
DOI from its [Zenodo record](https://doi.org/10.5281/zenodo.21848579) instead — v0.1.0 is
`10.5281/zenodo.21848580`. GitHub's "Cite this repository" button generates this from
[`CITATION.cff`](CITATION.cff) in other formats too.


## Dev

In typical software-dev fasion, every routine task has a `make` target. Just type `make` on its own to list them.

```bash
make test              # run the test suite
make check-upstream    # report fixture drift against the live API   [network]
make record-fixtures   # re-record test/fixtures/                    [network]
make bench             # storage size and reload benchmark
make portability       # read a file back from Go
```

### Tests

The test suite never touches the network. Requests are served by a `MockTransport` reading
recorded fixtures, and the real HTTP path is exercised against a throwaway server on
localhost, so everything is offline and deterministic. Only the two targets marked
`[network]` above reach the API, and they are never run as part of `make test`.

Checking that Delphi still behaves the way `test/fixtures/` records is a separate concern
with a different meaning — a red test should mean *our* code is wrong, not that someone
else's server moved. That lives in a script you run deliberately:

```bash
julia --project=. scripts/check_upstream.jl           # report drift
julia --project=. scripts/check_upstream.jl --write   # re-record the fixtures
```

It verifies the response *shape* rather than diffing bytes: the CSV header, the status
codes, and how each failure mode is signaled. The measurement values themselves change
whenever Delphi revises them, so a byte-exact comparison would report drift constantly.
Run it when touching `src/sources/`, or before tagging a release.
