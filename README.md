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
#                0.07, missing, missing, missing, missing,
#                Date("2026-08-01"), 10, :source, NOT_MISSING)

# Save table to disk
EpiDataKit.save(tbl, "nssp_covid.arrow")
tbl2 = EpiDataKit.load("nssp_covid.arrow")
```

The table is a Tables.jl source, so it goes straight into a `DataFrame` when you want one:

```julia
using DataFrames

df = DataFrame(tbl; copycols=false)
# 2×15 DataFrame
#  Row │ source  signal               geo_level  geo_id  period_start  period_end  v ⋯
#      │ Symbol  Symbol               GeoLevel   String  Dates.Date    Dates.Date  F ⋯
# ─────┼──────────────────────────────────────────────────────────────────────────────
#    1 │ nssp    pct_ed_visits_covid  STATE      ca      2026-05-17    2026-05-23    ⋯
#    2 │ nssp    pct_ed_visits_covid  STATE      ca      2026-05-24    2026-05-30    ⋯
#                                                                    9 columns omitted
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

### Epidata V5

Delphi stops adding new data to the older API on 2026-09-22. New data lands only in
[Epidata V5](https://cmu-delphi.github.io/delphi-epidata/api/v5.html), which is a different
host with a different shape. `fetch_snapshot` is the V5 counterpart of `fetch_covidcast`:

```julia
tbl = fetch_snapshot(
    source         = "nssp",
    signal         = "pct_ed_visits_covid",
    geo_type       = "state",
    geo_values     = ["ca", "ny"],
    reference_time = Date(2026, 1, 1):Date(2026, 6, 1),
)
```

The result is the same `EpiObservation` schema, so V4 and V5 tables still combine:

```julia
EpiDataKit.save(vcat(flu, tbl), "combined.arrow")
```

**One request returns everything.** V5 removed `geo_value` and `time_values` from the wire,
so a call downloads every location and every reference time for that signal and geographic
level. `geo_values` and `reference_time` filter what came back. Bind the result rather than
calling this in a loop, and expect a first call to be slower and larger than the V4
equivalent.

`fetch_archive` returns every revision instead of one row per key, which is what
backtesting needs:

```julia
hist = fetch_archive(
    source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state",
    geo_values = "ca", report_time = ">2026-06-01",
)
```

`report_time` takes an operator: `"=2026-06-26"` for one release, `"<"` or `">"` for a
range. Omit it and the server returns the whole report time history, which can be very
large. `fetch_epidata` picks the endpoint for you: pass `report_time` and it calls
`fetch_archive`, otherwise `fetch_snapshot`.

#### What changed from V4

| V4 | V5 |
|---|---|
| `data_source` | `source` |
| `geo_value = "ca"` | `geo_values = "ca"`, applied on the client |
| `time_values = "202620-202629"` | `reference_time = Date(a):Date(b)`, applied on the client |
| `as_of` | `snapshot_date`, and it takes a calendar date, not an epiweek |
| `issues` | `report_time`, on `fetch_archive` only |
| `time_type` | gone; `reference_time` is a calendar date and the resolution is inferred |
| `lag` as a filter | gone; still a column, computed from `report_time - reference_time` |
| `doctor-visits` | `claims_outpatient` |
| `hospital-admissions` | `claims_inpatient` |

`time_values`, `as_of`, and `issues` still work as argument names. Each warns once and maps
to the new one.

Two columns are new. `fill_method` says how nulls were handled during geographic
aggregation (`:source`, `:ave`, or `:zero`), and it is part of a row's identity upstream, so
an aggregated level returns the same period once per method. `ci_lower` and `ci_upper`
carry the uncertainty that `stderr` and `sample_size` carried in V4; a row has one pair or
the other, never both.

#### Which sources work

Working: `nssp`, `nhsn`, `claims_outpatient`, `claims_inpatient`, `nchs_mortality`,
`sleepcycle`, `va_respiratory`.

Not yet: `pophive`, `nickel_beta`, and `nwss` carry extra key columns such as `age_group`
and `pcr_target` that this schema has no field for, and `rvdss` publishes no metadata yet.
Asking for one names the reason. `fluview` had not moved to V5 as of 2026-09-08, so `fetch_fluview` still queries the older API. That API stops gaining data on 2026-09-22 too, so it stays correct for historical work.

`catalog(api = :v5)` lists what V5 serves, in one request:

```julia
cat = catalog(api = :v5)
unique(cat.source)
filter(e -> e.source === :nssp, cat)
```

V5 entries leave `time_type`, `num_locations`, `min_lag`, and `max_lag` `missing`, because
the metadata endpoint does not publish them. Call `catalog()` and `catalog(api = :v5)` and
`vcat` the results to see both, which is how you find what a V4 signal became.

#### Rate limits

V5 is stricter than V4: 60 requests/hour overall, 5/minute on `archive/`, and 3/minute on
`snapshot/`. Delphi's notice says an existing `DELPHI_EPIDATA_KEY` works on V5 without
re-registration and lifts these limits; this package did not measure that. V5 takes the
key in a `token` header rather than HTTP Basic, which `v5_transport()` sets for you.

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
```

`fetch_with` names the function to call, as a `Symbol`, so you map it to the actual function
by hand:

```julia
e = covid[1]
tbl = fetch_covidcast(data_source = String(e.source), signal = String(e.signal),
                      time_type = String(e.time_type), geo_type = "county",
                      time_values = e.last_period)

tbl[1]
# EpiObservation(:nssp, :pct_ed_visits_covid, COUNTY, "08001",
#                Date("2026-08-09"), Date("2026-08-15"),
#                0.15, missing, missing, missing, missing,
#                Date("2026-08-22"), 1, :source, NOT_MISSING)
```

```julia
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

Those rows are also the signal list, not verified coverage: they say the measure exists,
not that every level of it returns data when fetched. `num_age_2` is a known example — it is
`null` in every recorded fluview reply, so `fetch_fluview` returns no observations for it at
any level.

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
    ci_lower::Union{Float64,Missing}
    ci_upper::Union{Float64,Missing}
    issue::Union{Date,Missing}            # when it was published
    lag::Union{Int,Missing}               # periods between period_end and issue
    fill_method::Symbol                   # :source, :ave, or :zero
    missing_code::MissingCode             # why `value` is absent, when it is
end
```

`lag` is counted in the signal's own time units — days for a daily signal, weeks for a
weekly one — and stored as the source reported it. `issue - period_end` gives days either
way, and the schema deliberately does not record the time resolution, so a derived lag
would be seven times off for weekly signals with nothing to signal the mistake.

`fill_method` records how nulls were handled during geographic aggregation. V5 treats it as
part of a row's identity, so dropping it would merge rows that upstream keeps apart. V3 and
V4 rows are always `:source`.

`ci_lower` and `ci_upper` bound a confidence interval. V5 reports uncertainty this way for
some sources, where V3 and V4 reported `stderr` and `sample_size`. A row carries one pair
or the other.


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

Working now: the V5 `snapshot` and `archive` endpoints, and the V3/V4 `covidcast` and
`fluview` endpoints, end to end: fetch, retry with backoff, standardize, Arrow round
trip. Plus `catalog` over both APIs for discovering what is available, all with an offline
test suite.

Not yet: `catalog` does not cache, so each call costs a request, and no fetcher checks a
signal name against it before sending. V5 sources with extra key columns (`pophive`,
`nickel_beta`, `nwss`) are refused, because the schema has no field for `age_group` or
`pcr_target`. Also absent: a rate limiter, concurrent chunked fetch, an incremental
on-disk cache, and the V5 `aux_data` and `geomap` endpoints.

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
  version = {0.3.0},
  doi     = {10.5281/zenodo.21848579},
  url     = {https://github.com/svader0/EpiDataKit.jl}
}
```

That DOI resolves to whichever release is newest. To pin one release instead, take its
version DOI from the [Zenodo record](https://doi.org/10.5281/zenodo.21848579), which lists
one per release. GitHub's "Cite this repository" button generates this from
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
