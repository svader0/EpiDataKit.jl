using Dates
using Logging
using EpiDataKit: fetch_snapshot, fetch_archive, fetch_epidata, v5_params, request_key,
                  mock_response, V5_KEY_HEADER, V5_SNAPSHOT_ENDPOINT, V5_ARCHIVE_ENDPOINT,
                  NoResultsError, ValidationError, TransportError, EpidataError

function v5_mock(endpoint, body; status = 200, headers = Dict{String,String}(),
                 extra = Dict{String,String}(), kwargs...)
    key = request_key(endpoint, merge(v5_params(; kwargs...), extra))
    return MockTransport(Dict(key => mock_response(body; status, headers, request = key)))
end

const PAGINATED = Dict("use_pagination" => "true")

const SNAP_BODY = V5_KEY_HEADER * ",value\n" *
    "pct_ed_visits_covid,2026-06-26,state,ak,source,2022-10-01,1.61\n" *
    "pct_ed_visits_covid,2026-06-26,state,ca,source,2022-10-01,2.10\n" *
    "pct_ed_visits_covid,2026-06-26,state,ak,source,2022-10-08,1.31\n" *
    "pct_ed_visits_covid,2026-06-26,state,ca,source,2022-10-08,2.20\n"

const SNAP_Q = (source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state")

@testset "fetch_snapshot" begin
    @testset "end to end" begin
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, SNAP_BODY; SNAP_Q...)
        tbl = fetch_snapshot(; transport = t, SNAP_Q...)

        @test tbl isa EpiTable
        @test length(tbl) == 4
        @test tbl[1].source === :nssp
        @test tbl[1].period_end == Date(2022, 10, 1)
        @test tbl[1].period_start == Date(2022, 9, 25)
        @test length(t.calls) == 1
    end

    @testset "geo_values filters on the client, not the wire" begin
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, SNAP_BODY; SNAP_Q...)
        tbl = fetch_snapshot(; transport = t, geo_values = "ca", SNAP_Q...)

        @test length(tbl) == 2
        @test all(o -> o.geo_id == "ca", tbl)
        @test !occursin("geo_value=", only(t.calls))
        @test !occursin("time_values=", only(t.calls))
    end

    @testset "reference_time filters on the client" begin
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, SNAP_BODY; SNAP_Q...)
        tbl = fetch_snapshot(; transport = t,
                             reference_time = Date(2022, 10, 8), SNAP_Q...)
        @test length(tbl) == 2
        @test all(o -> o.period_end == Date(2022, 10, 8), tbl)
    end

    @testset "snapshot_date goes on the wire" begin
        q = (SNAP_Q..., snapshot_date = Date(2026, 7, 1))
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, SNAP_BODY; q...)
        fetch_snapshot(; transport = t, q...)
        @test occursin("snapshot_date=2026-07-01", only(t.calls))
    end

    @testset "several signals cost one request each" begin
        b1 = V5_KEY_HEADER * ",value\n" *
             "pct_ed_visits_covid,2026-06-26,state,ca,source,2022-10-01,2.10\n" *
             "pct_ed_visits_covid,2026-06-26,state,ca,source,2022-10-08,2.20\n"
        b2 = V5_KEY_HEADER * ",value\n" *
             "pct_ed_visits_influenza,2026-06-26,state,ca,source,2022-10-01,0.30\n" *
             "pct_ed_visits_influenza,2026-06-26,state,ca,source,2022-10-08,0.40\n"
        k1 = request_key(V5_SNAPSHOT_ENDPOINT,
                         v5_params(source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state"))
        k2 = request_key(V5_SNAPSHOT_ENDPOINT,
                         v5_params(source = "nssp", signal = "pct_ed_visits_influenza", geo_type = "state"))
        t = MockTransport(Dict(k1 => mock_response(b1; request = k1),
                               k2 => mock_response(b2; request = k2)))

        tbl = fetch_snapshot(source = "nssp", geo_type = "state", transport = t,
                             signal = ["pct_ed_visits_covid", "pct_ed_visits_influenza"])

        @test length(t.calls) == 2
        @test length(tbl) == 4
        @test Set(tbl.signal) == Set([:pct_ed_visits_covid, :pct_ed_visits_influenza])
    end

    @testset "a header-only reply is NoResultsError" begin
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, V5_KEY_HEADER * ",value\n"; SNAP_Q...)
        @test_throws NoResultsError fetch_snapshot(; transport = t, SNAP_Q...)
    end

    @testset "a filter that matches nothing is NoResultsError" begin
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, SNAP_BODY; SNAP_Q...)
        @test_throws NoResultsError fetch_snapshot(; transport = t,
                                                   geo_values = "zz", SNAP_Q...)
    end

    @testset "deprecated V4 argument names still work, with a warning" begin
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, SNAP_BODY; SNAP_Q...)
        tbl = @test_logs (:warn,) match_mode = :any fetch_snapshot(;
            transport = t, time_values = Date(2022, 10, 8), SNAP_Q...)
        @test length(tbl) == 2

        q = (SNAP_Q..., snapshot_date = Date(2026, 7, 1))
        t2 = v5_mock(V5_SNAPSHOT_ENDPOINT, SNAP_BODY; q...)
        tbl2 = @test_logs (:warn,) match_mode = :any fetch_snapshot(;
            transport = t2, as_of = Date(2026, 7, 1), SNAP_Q...)
        @test length(tbl2) == 4
    end

    @testset "one empty signal among several is skipped, not fatal" begin
        b1 = V5_KEY_HEADER * ",value\n" *
             "pct_ed_visits_covid,2026-06-26,state,ca,source,2022-10-01,2.10\n"
        k1 = request_key(V5_SNAPSHOT_ENDPOINT,
                         v5_params(source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state"))
        k2 = request_key(V5_SNAPSHOT_ENDPOINT,
                         v5_params(source = "nssp", signal = "pct_ed_visits_rsv", geo_type = "state"))
        t = MockTransport(Dict(k1 => mock_response(b1; request = k1),
                               k2 => mock_response(V5_KEY_HEADER * ",value\n"; request = k2)))
        tbl = fetch_snapshot(source = "nssp", geo_type = "state", transport = t,
                             signal = ["pct_ed_visits_covid", "pct_ed_visits_rsv"])
        @test length(t.calls) == 2
        @test length(tbl) == 1
        @test only(tbl).signal === :pct_ed_visits_covid
    end
end

@testset "fetch_archive" begin
    body = V5_KEY_HEADER * ",value\n" *
        "pct_ed_visits_covid,2026-06-26,state,ca,source,2022-10-01,2.10\n" *
        "pct_ed_visits_covid,2026-07-01,state,ca,source,2022-10-01,2.15\n" *
        "pct_ed_visits_covid,2026-06-26,state,ca,source,2022-10-08,2.20\n"
    q = (source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state")

    @testset "revisions come back as separate rows" begin
        t = v5_mock(V5_ARCHIVE_ENDPOINT, body; extra = PAGINATED, q...)
        tbl = fetch_archive(; transport = t, q...)

        @test length(tbl) == 3
        same = filter(o -> o.period_end == Date(2022, 10, 1), collect(tbl))
        @test Set(o.issue for o in same) == Set([Date(2026, 6, 26), Date(2026, 7, 1)])
    end

    @testset "report_time goes on the wire as report_time_query" begin
        qq = (q..., report_time = Date(2026, 6, 26))
        t = v5_mock(V5_ARCHIVE_ENDPOINT, body; extra = PAGINATED, qq...)
        fetch_archive(; transport = t, qq...)
        @test occursin("report_time_query=%3D2026-06-26", only(t.calls)) ||
              occursin("report_time_query==2026-06-26", only(t.calls))
    end

    @testset "pagination follows the Link header" begin
        page1 = V5_KEY_HEADER * ",value\n" *
                "pct_ed_visits_covid,2026-06-26,state,ca,source,2022-10-01,2.10\n"
        page2 = "pct_ed_visits_covid,2026-07-01,state,ca,source,2022-10-01,2.15\n"

        key = request_key(V5_ARCHIVE_ENDPOINT, merge(v5_params(; q...), PAGINATED))
        nxt = "https://delphi.cmu.edu/epidata/v5/archive/?page=2&header=false"
        nxt_key = request_key(nxt, Dict{String,String}())
        t = MockTransport(Dict(
            key => mock_response(page1; headers = Dict("Link" => "<$nxt>; rel=\"next\""),
                                 request = key),
            nxt_key => mock_response(page2; request = nxt_key)))

        tbl = fetch_archive(; transport = t, q...)
        @test length(t.calls) == 2
        @test length(tbl) == 2
        @test Set(tbl.issue) == Set([Date(2026, 6, 26), Date(2026, 7, 1)])
    end

    @testset "a failed later page is an error, not data" begin
        page1 = V5_KEY_HEADER * ",value\n" *
                "pct_ed_visits_covid,2026-06-26,state,ca,source,2022-10-01,2.10\n"
        key = request_key(V5_ARCHIVE_ENDPOINT, merge(v5_params(; q...), PAGINATED))
        nxt = "https://delphi.cmu.edu/epidata/v5/archive/?page=2&header=false"
        nxt_key = request_key(nxt, Dict{String,String}())
        t = MockTransport(Dict(
            key => mock_response(page1; headers = Dict("Link" => "<$nxt>; rel=\"next\""),
                                 request = key),
            nxt_key => mock_response("<html>502</html>"; status = 502, request = nxt_key)))
        @test_throws TransportError fetch_archive(; transport = t, q...)
    end

    @testset "a page without a trailing newline does not glue rows together" begin
        page1 = V5_KEY_HEADER * ",value\n" *
                "pct_ed_visits_covid,2026-06-26,state,ca,source,2022-10-01,2.10"
        page2 = "pct_ed_visits_covid,2026-07-01,state,ca,source,2022-10-01,2.15\n"
        key = request_key(V5_ARCHIVE_ENDPOINT, merge(v5_params(; q...), PAGINATED))
        nxt = "https://delphi.cmu.edu/epidata/v5/archive/?page=2&header=false"
        nxt_key = request_key(nxt, Dict{String,String}())
        t = MockTransport(Dict(
            key => mock_response(page1; headers = Dict("Link" => "<$nxt>; rel=\"next\""),
                                 request = key),
            nxt_key => mock_response(page2; request = nxt_key)))
        tbl = fetch_archive(; transport = t, q...)
        @test length(tbl) == 2
        @test Set(tbl.issue) == Set([Date(2026, 6, 26), Date(2026, 7, 1)])
    end
end

@testset "fetch_epidata routes" begin
    t1 = v5_mock(V5_SNAPSHOT_ENDPOINT, SNAP_BODY; SNAP_Q...)
    fetch_epidata(; transport = t1, SNAP_Q...)
    @test startswith(only(t1.calls), V5_SNAPSHOT_ENDPOINT)

    q = (SNAP_Q..., report_time = Date(2026, 6, 26))
    t2 = v5_mock(V5_ARCHIVE_ENDPOINT, SNAP_BODY; extra = PAGINATED, q...)
    fetch_epidata(; transport = t2, q...)
    @test startswith(only(t2.calls), V5_ARCHIVE_ENDPOINT)

    q3 = (SNAP_Q..., report_time = Date(2026, 6, 26))
    t3 = v5_mock(V5_ARCHIVE_ENDPOINT, SNAP_BODY; extra = PAGINATED, q3...)
    @test_logs (:warn,) match_mode = :any fetch_epidata(; transport = t3,
        issues = Date(2026, 6, 26), SNAP_Q...)
    @test startswith(only(t3.calls), V5_ARCHIVE_ENDPOINT)

    @test_throws ValidationError fetch_epidata(source = "nssp", signal = "x",
        geo_type = "state", snapshot_date = Date(2026, 7, 1),
        report_time = Date(2026, 6, 26), transport = MockTransport())
end

@testset "recorded V5 responses" begin
    @testset "snapshot" begin
        q = (source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state")
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, fixture("v5_snapshot_success.csv"); q...)
        tbl = fetch_snapshot(; transport = t, q...)

        @test tbl isa EpiTable
        @test !isempty(tbl)
        @test all(o -> o.source === :nssp, tbl)
        @test all(o -> o.geo_level == STATE, tbl)
        @test all(o -> o.period_end - o.period_start == Day(6), tbl)
        @test all(o -> dayofweek(o.period_end) == 6, tbl)
        @test all(o -> o.fill_method === :source, tbl)
        @test all(o -> o.stderr === missing, tbl)
    end

    @testset "no rows" begin
        q = (source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state")
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, fixture("v5_snapshot_noresults.csv"); q...)
        @test_throws NoResultsError fetch_snapshot(; transport = t, q...)
    end

    @testset "ci columns" begin
        q = (source = "sleepcycle", signal = "pct_cough_2_plus_7dav", geo_type = "state")
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, fixture("v5_snapshot_ci.csv"); q...)
        tbl = fetch_snapshot(; transport = t, q...)

        @test any(o -> o.ci_lower !== missing, tbl)
        @test all(o -> o.ci_lower === missing || o.ci_lower <= o.value <= o.ci_upper, tbl)
        @test all(o -> o.period_start == o.period_end, tbl)
    end

    @testset "422" begin
        q = (source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state")
        t = v5_mock(V5_SNAPSHOT_ENDPOINT, fixture("v5_validation_error.json");
                    status = 422, q...)
        e = try; fetch_snapshot(; transport = t, q...); nothing; catch err; err; end
        @test e isa EpidataError
        @test e.code == 422
        @test !isempty(e.message)
    end
end
