# Fixtures

Recorded from the live Delphi Epidata API — covidcast on 2026-08-02, fluview on 2026-08-04.
Base URL: `https://api.delphi.cmu.edu/epidata/`

## covidcast — endpoint `covidcast/`

| File | Status | Query |
|---|---|---|
| `covidcast_success.csv` | 200 | `data_source=nssp&signal=pct_ed_visits_covid&time_type=week&geo_type=state&time_values=202620-202621&geo_value=ca&format=csv` |
| `covidcast_noresults.csv` | 200 | same, but `time_values=199001` — body is **empty**, which is how CSV mode signals "no results" |
| `covidcast_validation_error.json` | **400** | `data_source=nssp&format=csv` — note the body is JSON even though `format=csv` was requested |
| `covidcast_noresults.json` | 200 | same as `noresults.csv` but without `format=csv`, for contrast: JSON mode uses `result: -2` |
| `covidcast_retired.json` | **410** | recorded 2026-11-20: `data_source=nssp&signal=pct_ed_visits_covid&time_type=week&geo_type=state&time_values=202645&geo_value=ca&format=csv` — V3 no longer serves time values after 2026-09-22; body is JSON with `result: -3` |
| `covidcast_truncated.json` | 200 | **synthetic.** `result: 2` was not reproducible on demand; the shape follows the documented code |

`covidcast_noresults.csv` is intentionally a zero-byte file. Do not "fix" it by adding a header
row — the empty body *is* the behavior under test.

## fluview — endpoint `fluview/`

| File | Status | Query |
|---|---|---|
| `fluview_success.json` | 200 | `epiweeks=202020-202021&regions=nat,hhs1` — 4 rows, `result: 1` |
| `fluview_noresults.json` | 200 | `epiweeks=199001&regions=nat` — `result: -2` |

fluview is JSON-only; no `format` parameter is sent. `decode_response` returns `epidata`
on `result: 1` before reaching the CSV header check, so both endpoints share it.

`num_age_2` is `null` in every row of `fluview_success.json`. That is real upstream data,
not a recording fault, and it is what pins the rule that a null measure produces no
observation rather than a missing-valued one.

## covidcast_meta — endpoint `covidcast_meta/`

| File | Status | Query |
|---|---|---|
| `covidcast_meta_success.csv` | 200 | `signals=nssp:pct_ed_visits_covid,chng:smoothed_outpatient_covid&format=csv` — 13 rows, both time types, 7 geo types |

The no-results case reuses `covidcast_noresults.csv`: this endpoint signals it the same way
`covidcast` does, with a zero-byte body at status 200. It answers an unrecognized
`geo_types` or `time_types` that way too, which is why `catalog_params` validates those
locally.

The fixture is two signals rather than the full 2,970-row reply on purpose. The parser cares
about the header, both time encodings, and the set of geo types, and none of those need
415 KB to pin.

To re-record, run the maintenance script rather than issuing these by hand — it holds the
same queries and rewrites every file here:

    make record-fixtures
    # or: julia --project=. scripts/check_upstream.jl --write

Without `--write` (`make check-upstream`) it only reports whether the upstream contract
still holds. It checks the response *shape* (header line, status codes, result codes), not
the values, because surveillance numbers are revised for weeks after publication and a
byte-exact comparison would report drift constantly.

A response that is not upstream speaking — a 429 from the rate limit, or a 5xx from a load
balancer — is never recorded, so a bad moment cannot overwrite a good fixture with an
error page.

Mind the anonymous rate limit of 60 requests/hour; each run costs 20 requests — 15 contract
checks plus 5 end-to-end calls.

## V5 — endpoint `v5/snapshot/`

Recorded 2026-11-20 from `https://delphi.cmu.edu/epidata/v5/` (anonymous; no token).

| File | Status | Query |
|---|---|---|
| `v5_snapshot_success.csv` | 200 | `source=nssp&signal=pct_ed_visits_covid&geo_type=state&geo_value=ca,ny&reference_times=2026-01-01:2026-01-31&format=csv` — 5 Saturdays x 2 states |
| `v5_snapshot_noresults.csv` | 200 | `source=nssp&signal=pct_ed_visits_covid&geo_type=state&snapshot_date=1990-01-01&format=csv` — **header line only**, which is how V5 says no results |
| `v5_validation_error.json` | **422** | `source=nssp&geo_type=state&format=csv` — `{"detail":[{"msg":…}],"code":"validation_error"}` |
| `v5_snapshot_strata.csv` | 200 | `source=fluview_ilinet&signal=num_ili&geo_type=nation&reference_times=2026-09-01:2026-09-30&format=csv` — has an `age_group` column |
| `v5_snapshot_daily_ci.csv` | 200 | `source=sleepcycle&signal=pct_cough_10_plus_7dav&geo_type=state&geo_value=ca&reference_times=2026-10-01:2026-10-07&format=csv` — daily, with `ci_lower,ci_upper` |

`sleepcycle` was chosen for the daily/CI case because `nickel_beta` was withdrawn from V5
between 2026-10-29 and 2026-11-20.

### `v5/archive/`

Recorded 2026-11-20, same host.

| File | Status | Query |
|---|---|---|
| `v5_archive_success.csv` | 200 | `source=nssp&signal=pct_ed_visits_covid&geo_type=state&geo_value=ca&reference_times=2026-09-01:2026-10-31&report_time_query=>=2026-10-01&format=csv` — several reference dates appear under more than one `report_time` |

V5 rows carry no `source` column and no time resolution, so neither is recoverable from a fixture.

### `v5/metadata/`

Recorded 2026-11-20, same host.

| File | Status | Query |
|---|---|---|
| `v5_metadata.json` | 200 | none — the whole object, one key per source, about 28 KB |

Tests derive their expectations from this file rather than hardcoding source or signal
counts, since the set of sources changes upstream.
