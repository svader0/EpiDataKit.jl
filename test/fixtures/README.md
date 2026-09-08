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

Mind the anonymous rate limit of 60 requests/hour; each run costs 10 requests — 7 contract
checks plus one end-to-end call per endpoint.

## Epidata V5, base URL `https://delphi.cmu.edu/epidata/v5/`

Recorded 2026-09-08. Different host from the tables above: `api.delphi.cmu.edu` answers
the V5 routes with a 404.

| File | Status | Query |
|---|---|---|
| `v5_snapshot_success.csv` | 200 | `snapshot/?source=nssp&signal=pct_ed_visits_covid&geo_type=state&limit=20&format=csv` |
| `v5_snapshot_noresults.csv` | 200 | same, but `signal=not_a_signal`. The body is the **header line only** |
| `v5_snapshot_ci.csv` | 200 | `snapshot/?source=sleepcycle&signal=pct_cough_2_plus_7dav&geo_type=state&limit=20&format=csv`. Has `ci_lower` and `ci_upper` |
| `v5_archive_success.csv` | 200 | `archive/?source=nssp&signal=pct_ed_visits_covid&geo_type=state&limit=20&use_pagination=true&format=csv` |
| `v5_validation_error.json` | **422** | `snapshot/?source=nssp&format=csv`. FastAPI `{"detail": [...]}`, no `result` code |
| `v5_metadata.json` | 200 | `metadata/`. Every source in one reply, about 9 KB |

`v5_snapshot_noresults.csv` is intentionally one line. Do not "fix" it by deleting the
header or by emptying the file: a header with no rows *is* how V5 says "no rows", and it is
also how V5 answers an unknown `geo_type` and a comma separated `signal` list. Those are
silent 200s, which is why `v5_params` validates locally.

`v5_snapshot_success.csv` holds weekly rows and `v5_snapshot_ci.csv` holds daily rows, on
purpose. V5 publishes no `time_type`, so `infer_time_type` reads the resolution from the
spacing of `reference_time`, and these two fixtures are what pin both branches of it.

Mind the V5 rate limits, which are tighter than V4's: 60 requests/hour overall, 5/minute
on `archive/`, and 3/minute on `snapshot/`. One `--write` run costs about 16 requests
across both APIs.
