#!/usr/bin/env julia
#
# Checks that Delphi's API still behaves the way test/fixtures/ says it does.
#
#     julia --project=. scripts/check_upstream.jl            # report only
#     julia --project=. scripts/check_upstream.jl --write     # re-record fixtures
#
# This is maintenance tooling, not a test. It is deliberately not part of `Pkg.test()`:
# a test asserts our code is correct, whereas this asserts someone else's server has not
# changed. Those have different failure meanings and belong in different places.
#
# Run it when touching src/sources/, before tagging a release, or when something upstream
# is suspected of having moved.
#
# ── Why the checks are semantic rather than byte-exact ──────────────────────────────────
#
# The success fixture's *numbers* change legitimately and often: surveillance values get
# revised for weeks after first publication, so a byte-for-byte diff would report drift
# constantly and train you to ignore it. What must stay stable is the response *shape*:
# the header line, the status codes, and how each failure mode is signaled. Those are
# what the parser depends on, and those are what this checks.
#
# It also exercises `fetch_raw(::HTTPTransport, ...)` end to end, which the offline suite
# never touches; every offline test goes through MockTransport, a different method
# entirely.

using Dates
using EpiDataKit
using EpiDataKit: HTTPTransport, fetch_raw, decode_response, standardize, body_string,
                  ratelimit, DelphiCovidcast, COVIDCAST_CSV_HEADER, COVIDCAST_ENDPOINT,
                  DelphiFluView, FLUVIEW_ENDPOINT, FLUVIEW_MEASURES,
                  COVIDCAST_META_ENDPOINT, COVIDCAST_META_CSV_HEADER,
                  V5_SNAPSHOT_ENDPOINT, V5_ARCHIVE_ENDPOINT, V5_METADATA_ENDPOINT,
                  V5_REFERENCE_TIMES_ENDPOINT, V5_CSV_HEADER_PREFIX, V5_COLUMNS

using JSON3

const FIXTURES = joinpath(@__DIR__, "..", "test", "fixtures")
const WRITE = "--write" in ARGS

# Splits a V5 CSV reply into its header columns and data lines, noting a wrong status or
# an empty body as problems. V5 never pads an empty result: it sends the header alone.
function v5_csv(resp)
    problems = String[]
    resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
    lines = split(strip(body_string(resp)), '\n')
    header = strip(lines[1])
    isempty(header) && push!(problems, "expected a CSV body, got an empty one")
    return problems, split(header, ','), lines[2:end]
end

# The prefix is what `decode_response` gates on; extra trailing columns are tolerated by
# the parser but must be known to standardize, or they are dropped.
function v5_header_problems(cols)
    problems = String[]
    startswith(join(cols, ','), V5_CSV_HEADER_PREFIX) ||
        push!(problems, "CSV header prefix changed\n      expected: $V5_CSV_HEADER_PREFIX\n      got:      $(join(cols, ','))")
    unknown = [c for c in cols if Symbol(c) ∉ V5_COLUMNS]
    isempty(unknown) || push!(problems, "columns missing from V5_COLUMNS: $(join(unknown, ", "))")
    return problems
end

# Column values of one named column across the data lines.
v5_column(cols, rows, name) =
    (i = findfirst(==(name), cols); i === nothing ? String[] : [split(r, ',')[i] for r in rows])

# Each entry: the query to send, the fixture it backs, and what must remain true of the
# response. `check` returns a list of problems; empty means the contract still holds.
const CHECKS = [
    (
        name = "CSV success",
        endpoint = COVIDCAST_ENDPOINT,
        fixture = "covidcast_success.csv",
        params = Dict("data_source" => "nssp", "signal" => "pct_ed_visits_covid",
                      "time_type" => "week", "geo_type" => "state",
                      "time_values" => "202620-202621", "geo_value" => "ca",
                      "format" => "csv"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            body = body_string(resp)
            lines = split(strip(body), '\n')
            if isempty(lines) || isempty(strip(body))
                push!(problems, "expected a CSV body, got an empty one")
                return problems
            end
            header = strip(lines[1])
            if header != COVIDCAST_CSV_HEADER
                # This is the single most consequential drift: decode_response uses the
                # header as its "is this the right shape" gate.
                push!(problems, "CSV header changed\n      expected: $COVIDCAST_CSV_HEADER\n      got:      $header")
            end
            length(lines) >= 2 || push!(problems, "expected at least one data row, got header only")
            return problems
        end,
    ),
    (
        name = "no results (CSV mode)",
        endpoint = COVIDCAST_ENDPOINT,
        fixture = "covidcast_noresults.csv",
        params = Dict("data_source" => "nssp", "signal" => "pct_ed_visits_covid",
                      "time_type" => "week", "geo_type" => "state",
                      "time_values" => "199001", "geo_value" => "ca", "format" => "csv"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            # The whole no-results contract in CSV mode: an empty body, with no result
            # code anywhere to consult. If this ever gains content, decode_response's
            # first branch is wrong.
            isempty(strip(body_string(resp))) ||
                push!(problems, "expected an empty body; got $(length(resp.body)) bytes")
            return problems
        end,
    ),
    (
        name = "validation error (JSON at 4xx)",
        endpoint = COVIDCAST_ENDPOINT,
        fixture = "covidcast_validation_error.json",
        params = Dict("data_source" => "nssp", "format" => "csv"),
        check = function (resp)
            problems = String[]
            # Note the status: validation failures do NOT use the "everything is 200"
            # convention, contrary to the usual advice about this API.
            resp.status == 400 || push!(problems, "expected status 400, got $(resp.status)")
            obj = try
                JSON3.read(body_string(resp))
            catch
                push!(problems, "expected a JSON body despite format=csv; got non-JSON")
                return problems
            end
            haskey(obj, :result) || push!(problems, "JSON body has no `result` field")
            if haskey(obj, :result) && obj.result != -1
                push!(problems, "expected result = -1, got $(obj.result)")
            end
            return problems
        end,
    ),
    (
        name = "no results (JSON mode)",
        endpoint = COVIDCAST_ENDPOINT,
        fixture = "covidcast_noresults.json",
        params = Dict("data_source" => "nssp", "signal" => "pct_ed_visits_covid",
                      "time_type" => "week", "geo_type" => "state",
                      "time_values" => "199001", "geo_value" => "ca"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            obj = try
                JSON3.read(body_string(resp))
            catch
                push!(problems, "expected a JSON body; got non-JSON")
                return problems
            end
            if !haskey(obj, :result) || obj.result != -2
                push!(problems, "expected result = -2, got $(get(obj, :result, "absent"))")
            end
            return problems
        end,
    ),
    (
        name = "fluview success",
        endpoint = FLUVIEW_ENDPOINT,
        fixture = "fluview_success.json",
        params = Dict("epiweeks" => "202020-202021", "regions" => "nat,hhs1"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            obj = try
                JSON3.read(body_string(resp))
            catch
                push!(problems, "expected a JSON body; got non-JSON")
                return problems
            end
            if !haskey(obj, :result) || obj.result != 1
                push!(problems, "expected result = 1, got $(get(obj, :result, "absent"))")
                return problems
            end
            rows = get(obj, :epidata, nothing)
            if rows === nothing || isempty(rows)
                push!(problems, "expected data rows, got none")
                return problems
            end
            # standardize reads these by name and fans out over the measures, so a rename
            # upstream is silent data loss rather than an error.
            for f in (:region, :epiweek, :issue)
                haskey(rows[1], f) || push!(problems, "row is missing the `$f` field")
            end
            present = [m for m in FLUVIEW_MEASURES if haskey(rows[1], m)]
            isempty(present) &&
                push!(problems, "no known measure fields present; FLUVIEW_MEASURES is stale")
            return problems
        end,
    ),
    (
        name = "fluview no results",
        endpoint = FLUVIEW_ENDPOINT,
        fixture = "fluview_noresults.json",
        params = Dict("epiweeks" => "199001", "regions" => "nat"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            obj = try
                JSON3.read(body_string(resp))
            catch
                push!(problems, "expected a JSON body; got non-JSON")
                return problems
            end
            if !haskey(obj, :result) || obj.result != -2
                push!(problems, "expected result = -2, got $(get(obj, :result, "absent"))")
            end
            return problems
        end,
    ),
    (
        name = "covidcast_meta CSV success",
        endpoint = COVIDCAST_META_ENDPOINT,
        fixture = "covidcast_meta_success.csv",
        params = Dict("signals" => "nssp:pct_ed_visits_covid,chng:smoothed_outpatient_covid",
                      "format" => "csv"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            body = body_string(resp)
            if isempty(strip(body))
                push!(problems, "expected a CSV body, got an empty one")
                return problems
            end
            lines = split(strip(body), '\n')
            header = strip(lines[1])
            if header != COVIDCAST_META_CSV_HEADER
                # decode_response gates on this header, exactly as it does for covidcast.
                push!(problems, "CSV header changed\n      expected: $COVIDCAST_META_CSV_HEADER\n      got:      $header")
            end
            length(lines) >= 2 || push!(problems, "expected at least one data row, got header only")
            return problems
        end,
    ),
    (
        name = "V5 snapshot success",
        endpoint = V5_SNAPSHOT_ENDPOINT,
        fixture = "v5_snapshot_success.csv",
        params = Dict("source" => "nssp", "signal" => "pct_ed_visits_covid",
                      "geo_type" => "state", "geo_value" => "ca,ny",
                      "reference_times" => "2026-01-01:2026-01-31", "format" => "csv"),
        check = function (resp)
            problems, cols, rows = v5_csv(resp)
            append!(problems, v5_header_problems(cols))
            isempty(rows) && push!(problems, "expected at least one data row, got header only")
            # Neither filter is documented; the fixture and its tests assume both hold.
            all(in(("ca", "ny")), v5_column(cols, rows, "geo_value")) ||
                push!(problems, "geo_value filter no longer restricts to ca,ny")
            all(d -> "2026-01-01" <= d <= "2026-01-31", v5_column(cols, rows, "reference_time")) ||
                push!(problems, "reference_times filter no longer restricts to January 2026")
            return problems
        end,
    ),
    (
        name = "V5 no results",
        endpoint = V5_SNAPSHOT_ENDPOINT,
        fixture = "v5_snapshot_noresults.csv",
        params = Dict("source" => "nssp", "signal" => "pct_ed_visits_covid",
                      "geo_type" => "state", "snapshot_date" => "1990-01-01",
                      "format" => "csv"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            n = length(split(strip(body_string(resp)), '\n'))
            n == 1 || push!(problems, "expected the header line alone, got $n lines")
            return problems
        end,
    ),
    (
        name = "V5 validation error",
        endpoint = V5_SNAPSHOT_ENDPOINT,
        fixture = "v5_validation_error.json",
        params = Dict("source" => "nssp", "geo_type" => "state", "format" => "csv"),
        check = function (resp)
            problems = String[]
            resp.status == 422 || push!(problems, "expected status 422, got $(resp.status)")
            obj = try
                JSON3.read(body_string(resp))
            catch
                push!(problems, "expected a JSON body despite format=csv; got non-JSON")
                return problems
            end
            obj isa AbstractDict && get(obj, :detail, nothing) isa AbstractVector ||
                push!(problems, "JSON body has no `detail` array")
            return problems
        end,
    ),
    (
        name = "V5 strata",
        endpoint = V5_SNAPSHOT_ENDPOINT,
        fixture = "v5_snapshot_strata.csv",
        params = Dict("source" => "fluview_ilinet", "signal" => "num_ili",
                      "geo_type" => "nation", "reference_times" => "2026-09-01:2026-09-30",
                      "format" => "csv"),
        check = function (resp)
            problems, cols, _ = v5_csv(resp)
            "age_group" in cols || push!(problems, "header has no `age_group` column")
            append!(problems, v5_header_problems(cols))
            return problems
        end,
    ),
    (
        name = "V5 daily with CI",
        endpoint = V5_SNAPSHOT_ENDPOINT,
        fixture = "v5_snapshot_daily_ci.csv",
        params = Dict("source" => "sleepcycle", "signal" => "pct_cough_10_plus_7dav",
                      "geo_type" => "state", "geo_value" => "ca",
                      "reference_times" => "2026-10-01:2026-10-07", "format" => "csv"),
        check = function (resp)
            problems, cols, _ = v5_csv(resp)
            for c in ("ci_lower", "ci_upper")
                c in cols || push!(problems, "header has no `$c` column")
            end
            append!(problems, v5_header_problems(cols))
            return problems
        end,
    ),
    (
        name = "V5 archive",
        endpoint = V5_ARCHIVE_ENDPOINT,
        fixture = "v5_archive_success.csv",
        params = Dict("source" => "nssp", "signal" => "pct_ed_visits_covid",
                      "geo_type" => "state", "geo_value" => "ca",
                      "reference_times" => "2026-09-01:2026-10-31",
                      "report_time_query" => ">=2026-10-01", "format" => "csv"),
        check = function (resp)
            problems, cols, rows = v5_csv(resp)
            append!(problems, v5_header_problems(cols))
            isempty(rows) && push!(problems, "expected at least one data row, got header only")
            return problems
        end,
    ),
    (
        name = "V5 metadata",
        endpoint = V5_METADATA_ENDPOINT,
        fixture = "v5_metadata.json",
        params = Dict{String,String}(),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            obj = try
                JSON3.read(body_string(resp))
            catch
                push!(problems, "expected a JSON body; got non-JSON")
                return problems
            end
            entry = get(obj, :nssp, nothing)
            if entry === nothing
                push!(problems, "metadata has no `nssp` entry")
                return problems
            end
            for f in (:signals, :geo_types, :reference_time_range, :report_time_range)
                haskey(entry, f) || push!(problems, "nssp entry is missing `$f`")
            end
            return problems
        end,
    ),
    (
        name = "V5 reference times",
        endpoint = V5_REFERENCE_TIMES_ENDPOINT,
        fixture = "v5_reference_times.json",
        params = Dict("source" => "nssp", "signal" => "pct_ed_visits_covid"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            obj = try
                JSON3.read(body_string(resp))
            catch
                push!(problems, "expected a JSON body; got non-JSON")
                return problems
            end
            # The only way fetch_snapshot can tell weekly from daily on a single date.
            ref = obj isa AbstractDict ? get(obj, :reference_times, nothing) : nothing
            if !(ref isa AbstractVector)
                push!(problems, "JSON body has no `reference_times` array")
            elseif !all(d -> d isa AbstractString && tryparse(Date, d) !== nothing, ref)
                push!(problems, "`reference_times` holds something other than ISO dates")
            end
            return problems
        end,
    ),
    (
        name = "V3 retired",
        endpoint = COVIDCAST_ENDPOINT,
        fixture = "covidcast_retired.json",
        params = Dict("data_source" => "nssp", "signal" => "pct_ed_visits_covid",
                      "time_type" => "week", "geo_type" => "state",
                      "time_values" => "202645", "geo_value" => "ca", "format" => "csv"),
        check = function (resp)
            problems = String[]
            resp.status == 410 || push!(problems, "expected status 410, got $(resp.status)")
            obj = try
                JSON3.read(body_string(resp))
            catch
                push!(problems, "expected a JSON body; got non-JSON")
                return problems
            end
            get(obj, :result, nothing) == -3 ||
                push!(problems, "expected result = -3, got $(get(obj, :result, "absent"))")
            return problems
        end,
    ),
]

function main()
    transport = HTTPTransport()
    if transport.api_key === nothing
        @info "No DELPHI_EPIDATA_KEY set; using the anonymous 60 requests/hour limit."
    end

    failed = 0
    last_resp = nothing

    println("Checking ", length(CHECKS), " upstream contracts against Delphi's V3 and V5 hosts\n")

    for c in CHECKS
        print("  ", rpad(c.name, 34))
        resp = try
            fetch_raw(transport, c.endpoint, c.params)
        catch e
            println("ERROR")
            println("      request failed: ", sprint(showerror, e))
            failed += 1
            continue
        end
        last_resp = resp

        problems = c.check(resp)
        if isempty(problems)
            println("ok")
        else
            println("DRIFT")
            for p in problems
                println("      - ", p)
            end
            failed += 1
        end

        # Rewriting on DRIFT is the point of --write: upstream moved, re-record it. What
        # must not be recorded is a response that is not upstream speaking at all: a 429
        # from the rate limit or a 5xx from a load balancer would otherwise overwrite a
        # good fixture with an error page, and the next test run would pin *that*.
        if WRITE
            if resp.status == 429 || resp.status >= 500
                println("      NOT rewriting ", c.fixture,
                        ": status $(resp.status) is a server-side failure, not a recording")
            else
                path = joinpath(FIXTURES, c.fixture)
                write(path, resp.body)
                println("      rewrote ", c.fixture, " (", length(resp.body), " bytes)")
            end
        end
    end

    # End-to-end through the public entry point. This is the only exercise the real
    # HTTPTransport fetch path gets anywhere in the repo; the offline suite substitutes
    # MockTransport, which is a separate method.
    print("  ", rpad("fetch_covidcast end to end", 34))
    try
        tbl = fetch_covidcast(
            data_source = "nssp", signal = "pct_ed_visits_covid",
            time_type = "week", geo_type = "state",
            time_values = "202620-202629", geo_value = "ca",
        )
        if length(tbl) == 0
            println("DRIFT")
            println("      returned zero rows for a window that previously had data")
            failed += 1
        else
            bad = filter(o -> o.period_end - o.period_start != Day(6), collect(tbl))
            if !isempty(bad)
                println("DRIFT")
                println("      $(length(bad)) weekly rows are not 7-day spans")
                failed += 1
            else
                println("ok (", length(tbl), " rows)")
            end
        end
    catch e
        println("ERROR")
        println("      ", sprint(showerror, e))
        failed += 1
    end

    print("  ", rpad("fetch_fluview end to end", 34))
    try
        tbl = fetch_fluview(epiweeks = "202020-202021", regions = ["nat", "hhs1"])
        if length(tbl) == 0
            println("DRIFT")
            println("      returned zero rows for a window that previously had data")
            failed += 1
        else
            println("ok (", length(tbl), " rows, ",
                    length(unique(tbl.signal)), " signals)")
        end
    catch e
        println("ERROR")
        println("      ", sprint(showerror, e))
        failed += 1
    end

    print("  ", rpad("fetch_snapshot end to end", 34))
    try
        tbl = fetch_snapshot(source = "nssp", signal = "pct_ed_visits_covid",
                             geo_type = "state", geo_values = "ca",
                             reference_times = "2026-01-01:2026-01-31")
        if length(tbl) == 0
            println("DRIFT")
            println("      returned zero rows for a window that previously had data")
            failed += 1
        else
            bad = filter(o -> o.period_end - o.period_start != Day(6), collect(tbl))
            if !isempty(bad)
                println("DRIFT")
                println("      $(length(bad)) weekly rows are not 7-day spans")
                failed += 1
            else
                println("ok (", length(tbl), " rows)")
            end
        end
    catch e
        println("ERROR")
        println("      ", sprint(showerror, e))
        failed += 1
    end

    print("  ", rpad("fetch_archive end to end", 34))
    try
        tbl = fetch_archive(source = "nssp", signal = "pct_ed_visits_covid",
                            geo_type = "state", geo_values = "ca",
                            reference_times = "2026-09-01:2026-10-31",
                            report_time = ">=2026-10-01")
        if length(tbl) == 0
            println("DRIFT")
            println("      returned zero rows for a window that previously had data")
            failed += 1
        else
            println("ok (", length(tbl), " rows)")
        end
    catch e
        println("ERROR")
        println("      ", sprint(showerror, e))
        failed += 1
    end

    print("  ", rpad("catalog end to end", 34))
    try
        cat = catalog()
        if length(cat) == 0
            println("DRIFT")
            println("      returned zero entries")
            failed += 1
        elseif :fluview ∉ cat.source
            println("DRIFT")
            println("      the static fluview half is missing")
            failed += 1
        elseif :fetch_snapshot ∉ cat.fetch_with
            println("DRIFT")
            println("      the V5 half is missing")
            failed += 1
        else
            println("ok (", length(cat), " entries, ",
                    length(unique(cat.source)), " sources)")
        end
    catch e
        println("ERROR")
        println("      ", sprint(showerror, e))
        failed += 1
    end

    if last_resp !== nothing
        rl = ratelimit(last_resp)
        rl.remaining === nothing ||
            println("\n  quota: ", rl.remaining, "/", something(rl.limit, "?"), " requests remaining")
    end

    println()
    if failed == 0
        println("All upstream contracts hold. Fixtures in test/fixtures/ are still accurate.")
        if !WRITE
            println("(`--write` re-records them anyway, e.g. to refresh the sample values.)")
        end
        return 0
    end

    println(failed, " contract(s) drifted.")
    println()
    println("What to do:")
    println("  1. Re-record with: julia --project=. scripts/check_upstream.jl --write")
    println("  2. If the CSV header changed, update COVIDCAST_CSV_HEADER in src/sources/delphi.jl.")
    println("  3. If the covidcast_meta header changed, update COVIDCAST_META_CSV_HEADER in src/catalog.jl.")
    println("  4. If a status or result code changed, update decode_response and its tests.")
    println("  5. If the V5 header prefix changed, update V5_CSV_HEADER_PREFIX in src/sources/delphi_v5.jl.")
    println("  6. If a new V5 column appears, update V5_COLUMNS in src/standardize.jl and the schema.")
    println("  7. Run the offline suite: julia --project=. -e 'using Pkg; Pkg.test()'")
    return 1
end

exit(main())
