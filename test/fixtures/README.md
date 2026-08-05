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

Mind the anonymous rate limit of 60 requests/hour; each run costs 8 requests — 6 contract
checks plus one end-to-end fetch per endpoint.
