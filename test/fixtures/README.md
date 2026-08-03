# Fixtures

Recorded from the live Delphi Epidata API on 2026-08-02. Base URL for every query:

    https://api.delphi.cmu.edu/epidata/covidcast/

| File | Status | Query |
|---|---|---|
| `covidcast_success.csv` | 200 | `data_source=nssp&signal=pct_ed_visits_covid&time_type=week&geo_type=state&time_values=202620-202621&geo_value=ca&format=csv` |
| `covidcast_noresults.csv` | 200 | same, but `time_values=199001` — body is **empty**, which is how CSV mode signals "no results" |
| `covidcast_validation_error.json` | **400** | `data_source=nssp&format=csv` — note the body is JSON even though `format=csv` was requested |
| `covidcast_noresults.json` | 200 | same as `noresults.csv` but without `format=csv`, for contrast: JSON mode uses `result: -2` |
| `covidcast_truncated.json` | 200 | **synthetic.** `result: 2` was not reproducible on demand; the shape follows the documented code |

`covidcast_noresults.csv` is intentionally a zero-byte file. Do not "fix" it by adding a header
row — the empty body *is* the behaviour under test.

To re-record, run the maintenance script rather than issuing these by hand — it holds the
same queries and rewrites every file here:

    julia --project=. scripts/check_upstream.jl --write

Without `--write` it only reports whether the upstream contract still holds. It checks the
response *shape* (header line, status codes, result codes), not the values, because
surveillance numbers are revised for weeks after publication and a byte-exact comparison
would report drift constantly.

Mind the anonymous rate limit of 60 requests/hour; each run costs 5 requests.
