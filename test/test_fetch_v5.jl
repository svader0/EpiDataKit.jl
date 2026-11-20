using Dates
using EpiDataKit: fetch_snapshot, fetch_archive, mock_response, request_key, v5_params,
                  format_v5_times, V5_SNAPSHOT_ENDPOINT, V5_ARCHIVE_ENDPOINT,
                  V5_METADATA_ENDPOINT, V5_REFERENCE_TIMES_ENDPOINT

function v5_entry(ep, body, params; status = 200)
    key = request_key(ep, params)
    return key => mock_response(body; status = status, request = key)
end

const V5Q = (source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state")
const V5_META = """{"nssp":{"signals":["pct_ed_visits_covid"],"geo_types":["state"]}}"""
const V5_HEADER = "signal,report_time,geo_type,geo_value,fill_method,reference_time,value\n"

@testset "fetch_v5" begin
    @testset "v5_params builds the wire query" begin
        p = v5_params(; V5Q..., geo_values = ["ca", "ny"],
                      reference_times = Date(2026, 1, 1):Date(2026, 1, 31))
        @test p == Dict("source" => "nssp", "signal" => "pct_ed_visits_covid",
                        "geo_type" => "state", "geo_value" => "ca,ny",
                        "reference_times" => "2026-01-01:2026-01-31", "format" => "csv")
    end

    @testset "geo_values are normalized for their level" begin
        p = v5_params(; source = "x", signal = "y", geo_type = "county", geo_values = [6075, "06001"])
        @test p["geo_value"] == "06075,06001"
        p = v5_params(; V5Q..., geo_values = "ca, NY")
        @test p["geo_value"] == "ca,ny"
        @test !haskey(v5_params(; V5Q..., geo_values = "*"), "geo_value")
        @test_throws ValidationError v5_params(; V5Q..., geo_values = String[])
    end

    @testset "geo_type accepts a GeoLevel and the alias" begin
        @test v5_params(; source = "x", signal = "y", geo_type = STATE)["geo_type"] == "state"
        @test v5_params(; source = "x", signal = "y", geo_type = "hhs_region")["geo_type"] == "hhs"
    end

    @testset "time selections" begin
        @test format_v5_times(Date(2026, 1, 3)) == "2026-01-03:2026-01-03"
        @test format_v5_times(">=2026-01-01") == ">=2026-01-01"
        @test format_v5_times([Date(2026, 1, 3), ">=2026-02-01"]) ==
              "2026-01-03:2026-01-03,>=2026-02-01"
        @test format_v5_times("*") === nothing
        @test format_v5_times(nothing) === nothing
        @test format_v5_times("2026-01-03") == "2026-01-03:2026-01-03"
        @test_throws ValidationError format_v5_times("soon")
        @test_throws ValidationError format_v5_times(3)
        @test_throws ValidationError format_v5_times(Date(2026, 1, 3); bare_dates = false)
        @test format_v5_times(Date(2026, 1, 1):Date(2026, 1, 2); bare_dates = false) ==
              "2026-01-01:2026-01-02"
    end

    @testset "snapshot_date forms" begin
        @test v5_params(; V5Q..., snapshot_date = Date(2026, 10, 1))["snapshot_date"] == "2026-10-01"
        @test v5_params(; V5Q..., snapshot_date = "2025-10-16T13:45:00Z")["snapshot_date"] ==
              "2025-10-16T13:45:00Z"
        @test_throws ValidationError v5_params(; V5Q..., snapshot_date = "yesterday")
        @test_throws ValidationError v5_params(; V5Q..., snapshot_date = Date(2026, 10, 1),
                                               report_time = ">=2026-10-01")
    end

    @testset "age_group becomes extra_keys" begin
        @test v5_params(; V5Q..., age_group = ["0-4", "all"])["extra_keys"] ==
              "age_group:0-4,age_group:all"
    end

    @testset "a typo is caught before any request" begin
        t = MockTransport()
        @test_throws ValidationError fetch_snapshot(; V5Q..., geo_type = "planet", transport = t)
        @test_throws ValidationError fetch_archive(; V5Q..., report_time = Date(2026, 10, 1),
                                                   transport = t)
        @test isempty(t.calls)
    end

    q1 = (; V5Q..., geo_values = ["ca", "ny"],
          reference_times = Date(2026, 1, 1):Date(2026, 1, 31))

    @testset "fetch_snapshot end to end" begin
        t = MockTransport(Dict(v5_entry(V5_SNAPSHOT_ENDPOINT, fixture("v5_snapshot_success.csv"),
                                        v5_params(; q1...))))
        tbl = fetch_snapshot(; transport = t, q1...)
        @test tbl isa EpiTable
        @test length(tbl) == 10
        @test length(t.calls) == 1
    end

    @testset "a misspelled signal names the real ones" begin
        q = (; V5Q..., signal = "pct_ed_visits_covd")
        t = MockTransport(Dict(
            v5_entry(V5_SNAPSHOT_ENDPOINT, fixture("v5_snapshot_noresults.csv"), v5_params(; q...)),
            v5_entry(V5_METADATA_ENDPOINT, V5_META, Dict("source" => "nssp"))))
        err = try fetch_snapshot(; transport = t, q...) catch e e end
        @test err isa ValidationError
        @test occursin("pct_ed_visits_covid", err.msg)
        @test length(t.calls) == 2
    end

    @testset "a genuinely empty window stays NoResultsError" begin
        q = (; V5Q..., snapshot_date = Date(1990, 1, 1))
        t = MockTransport(Dict(
            v5_entry(V5_SNAPSHOT_ENDPOINT, fixture("v5_snapshot_noresults.csv"), v5_params(; q...)),
            v5_entry(V5_METADATA_ENDPOINT, V5_META, Dict("source" => "nssp"))))
        @test_throws NoResultsError fetch_snapshot(; transport = t, q...)
    end

    @testset "one reference date resolves its resolution from metadata" begin
        q = (; V5Q..., geo_values = "ca", reference_times = Date(2026, 1, 3))
        body = V5_HEADER * "pct_ed_visits_covid,2026-01-10T12:00:00Z,state,ca,source,2026-01-03,0.5\n"
        for (dates, width) in ((["2025-12-27", "2026-01-03"], Day(6)),
                               (["2026-01-02", "2026-01-03"], Day(0)))
            ref = """{"reference_times":["$(join(dates, "\",\""))"]}"""
            t = MockTransport(Dict(
                v5_entry(V5_SNAPSHOT_ENDPOINT, body, v5_params(; q...)),
                v5_entry(V5_REFERENCE_TIMES_ENDPOINT, ref,
                         Dict("source" => "nssp", "signal" => "pct_ed_visits_covid"))))
            tbl = fetch_snapshot(; transport = t, q...)
            @test tbl[1].period_end - tbl[1].period_start == width
            @test length(t.calls) == 2
        end
    end

    @testset "fetch_archive returns revisions" begin
        q = (; V5Q..., geo_values = "ca", reference_times = Date(2026, 9, 1):Date(2026, 10, 31),
             report_time = ">=2026-10-01")
        t = MockTransport(Dict(v5_entry(V5_ARCHIVE_ENDPOINT, fixture("v5_archive_success.csv"),
                                        v5_params(; q...))))
        tbl = fetch_archive(; transport = t, q...)
        @test any(ps -> length(unique(tbl.issue[tbl.period_start .== ps])) > 1,
                  unique(tbl.period_start))
        @test all(>=(Date(2026, 10, 1)), tbl.issue)
    end
end
