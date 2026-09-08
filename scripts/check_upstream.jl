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
                  v5_transport, decode_v5, v5_error_message, V5_KEY_HEADER,
                  V5_SNAPSHOT_ENDPOINT, V5_ARCHIVE_ENDPOINT, V5_METADATA_ENDPOINT,
                  V5_SOURCES, fetch_snapshot, fetch_archive, DelphiV5, next_link

using JSON3

const FIXTURES = joinpath(@__DIR__, "..", "test", "fixtures")
const WRITE = "--write" in ARGS

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
]

# The V5 API is a different host with a different failure protocol, so its contracts get
# their own transport and their own list. Rate limits are tighter here: 3 requests/minute
# on snapshot and 5 on archive, so this list stays short on purpose.
const CHECKS_V5 = [
    (
        name = "v5 snapshot success",
        endpoint = V5_SNAPSHOT_ENDPOINT,
        fixture = "v5_snapshot_success.csv",
        params = Dict("source" => "nssp", "signal" => "pct_ed_visits_covid",
                      "geo_type" => "state", "limit" => "20", "format" => "csv"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            body = strip(body_string(resp))
            lines = split(body, '\n')
            if isempty(body)
                push!(problems, "expected a CSV body, got an empty one")
                return problems
            end
            # decode_v5 gates a 200 body on this prefix.
            startswith(strip(lines[1]), V5_KEY_HEADER) ||
                push!(problems, "key header changed\n      expected prefix: $V5_KEY_HEADER\n      got: $(strip(lines[1]))")
            length(lines) >= 2 || push!(problems, "expected at least one data row, got header only")
            # nssp is weekly, and every weekly reference_time observed is a Saturday.
            if length(lines) >= 2
                cols = split(strip(lines[2]), ',')
                length(cols) >= 6 || push!(problems, "row has fewer than 6 key columns")
                if length(cols) >= 6
                    d = tryparse(Date, cols[6])
                    d === nothing ? push!(problems, "reference_time $(cols[6]) is not YYYY-MM-DD") :
                        (dayofweek(d) == 6 ||
                         push!(problems, "weekly reference_time $d is not a Saturday"))
                end
            end
            return problems
        end,
    ),
    (
        name = "v5 no rows is header only",
        endpoint = V5_SNAPSHOT_ENDPOINT,
        fixture = "v5_snapshot_noresults.csv",
        params = Dict("source" => "nssp", "signal" => "not_a_signal",
                      "geo_type" => "state", "format" => "csv"),
        check = function (resp)
            problems = String[]
            # The whole no-rows contract: a 200 whose body is the header and nothing else.
            # If this ever becomes an error status or an empty body, decode_v5's last two
            # branches are wrong.
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            body = strip(body_string(resp))
            startswith(body, V5_KEY_HEADER) ||
                push!(problems, "expected the key header, got $(first(body, 100))")
            occursin('\n', body) &&
                push!(problems, "expected header only; got $(count(==('\n'), body) + 1) lines")
            return problems
        end,
    ),
    (
        name = "v5 ci columns",
        endpoint = V5_SNAPSHOT_ENDPOINT,
        fixture = "v5_snapshot_ci.csv",
        params = Dict("source" => "sleepcycle", "signal" => "pct_cough_2_plus_7dav",
                      "geo_type" => "state", "limit" => "20", "format" => "csv"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            header = strip(first(split(strip(body_string(resp)), '\n')))
            startswith(header, V5_KEY_HEADER) ||
                push!(problems, "key header changed: $header")
            for c in ("ci_lower", "ci_upper", "value")
                occursin(c, header) || push!(problems, "header has no `$c` column: $header")
            end
            return problems
        end,
    ),
    (
        name = "v5 archive success",
        endpoint = V5_ARCHIVE_ENDPOINT,
        fixture = "v5_archive_success.csv",
        params = Dict("source" => "nssp", "signal" => "pct_ed_visits_covid",
                      "geo_type" => "state", "limit" => "20", "format" => "csv",
                      "use_pagination" => "true"),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            startswith(strip(body_string(resp)), V5_KEY_HEADER) ||
                push!(problems, "key header changed")
            # Pagination is how fetch_archive avoids an unbounded body.
            next_link(resp) === nothing &&
                push!(problems, "use_pagination=true produced no `Link: rel=next` header")
            return problems
        end,
    ),
    (
        name = "v5 validation error (422)",
        endpoint = V5_SNAPSHOT_ENDPOINT,
        fixture = "v5_validation_error.json",
        params = Dict("source" => "nssp", "format" => "csv"),
        check = function (resp)
            problems = String[]
            resp.status == 422 || push!(problems, "expected status 422, got $(resp.status)")
            msg = v5_error_message(body_string(resp))
            msg === nothing && push!(problems, "body is not a FastAPI `detail` array")
            return problems
        end,
    ),
    (
        name = "v5 metadata",
        endpoint = V5_METADATA_ENDPOINT,
        fixture = "v5_metadata.json",
        params = Dict{String,String}(),
        check = function (resp)
            problems = String[]
            resp.status == 200 || push!(problems, "expected status 200, got $(resp.status)")
            obj = try
                JSON3.read(body_string(resp))
            catch
                push!(problems, "expected JSON; got non-JSON")
                return problems
            end
            for s in V5_SOURCES
                haskey(obj, s) || push!(problems, "metadata/ no longer lists `$s`")
            end
            if haskey(obj, :nssp)
                for f in (:signals, :geo_types, :reference_time_range, :report_time_range)
                    haskey(obj.nssp, f) ||
                        push!(problems, "nssp metadata is missing the `$f` field")
                end
                # A source gaining extra key columns means its rows no longer fit the schema.
                ek = get(obj.nssp, :extra_key_columns, nothing)
                ek === nothing || isempty(ek) ||
                    push!(problems, "nssp gained extra key columns: $ek")
            end
            return problems
        end,
    ),
]

function run_checks(checks, transport, label; pause::Real = 0)
    failed = 0
    last_resp = nothing
    println("Checking ", length(checks), " upstream contracts against ", label, "\n")

    for (i, c) in enumerate(checks)
        i > 1 && sleep(pause)
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
    return (failed, last_resp)
end

function main()
    transport = HTTPTransport()
    if transport.api_key === nothing
        @info "No DELPHI_EPIDATA_KEY set; using the anonymous 60 requests/hour limit."
    end

    failed, last_resp = run_checks(CHECKS, transport, "api.delphi.cmu.edu")

    v5 = v5_transport()
    # 3 requests/minute on snapshot, so pace the V5 half rather than racing it.
    v5_failed, _ = run_checks(CHECKS_V5, v5, "delphi.cmu.edu/epidata/v5"; pause = 21)
    failed += v5_failed

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
        else
            println("ok (", length(cat), " entries, ",
                    length(unique(cat.source)), " sources)")
        end
    catch e
        println("ERROR")
        println("      ", sprint(showerror, e))
        failed += 1
    end

    print("  ", rpad("fetch_snapshot end to end", 34))
    try
        sleep(21)  # stay under the 3 requests/minute snapshot limit
        tbl = fetch_snapshot(source = "nssp", signal = "pct_ed_visits_covid",
                             geo_type = "state", geo_values = "ca",
                             reference_time = Date(2026, 1, 1):Date(2026, 6, 1))
        if length(tbl) == 0
            println("DRIFT")
            println("      returned zero rows for a window that previously had data")
            failed += 1
        else
            bad = filter(o -> o.period_end - o.period_start != Day(6), collect(tbl))
            if !isempty(bad)
                println("DRIFT")
                println("      $(length(bad)) nssp rows are not 7-day spans; ",
                        "infer_time_type read the resolution wrong")
                failed += 1
            elseif any(o -> o.geo_id != "ca", tbl)
                println("DRIFT")
                println("      the client-side geo_values filter let another state through")
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

    print("  ", rpad("catalog(api = :v5) end to end", 34))
    try
        cat = catalog(api = :v5)
        if length(cat) == 0
            println("DRIFT")
            println("      returned zero entries")
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
    println("  5. Run the offline suite: julia --project=. -e 'using Pkg; Pkg.test()'")
    println("  6. If the V5 key header changed, update V5_KEY_HEADER in src/sources/v5.jl.")
    println("  7. If a V5 source appeared or gained extra key columns, update V5_SOURCES")
    println("     and V5_UNSUPPORTED_SOURCES in src/sources/v5.jl.")
    return 1
end

exit(main())
