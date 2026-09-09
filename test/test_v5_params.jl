using Dates
using StructArrays
using EpiDataKit: v5_params, check_v5_source, filter_observations,
                  format_report_time_query, V5_SNAPSHOT_ENDPOINT, ValidationError

const V5_Q = (source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state")

@testset "check_v5_source" begin
    @test check_v5_source("nssp") === :nssp
    @test check_v5_source(:NHSN) === :nhsn
    @test check_v5_source(" claims_outpatient ") === :claims_outpatient

    for s in ("pophive", "nwss", "nickel_beta")
        e = try; check_v5_source(s); nothing; catch err; err; end
        @test e isa ValidationError
        @test occursin("extra key", e.msg)
    end

    e = try; check_v5_source("rvdss"); nothing; catch err; err; end
    @test e isa ValidationError

    e = try; check_v5_source("doctor-visits"); nothing; catch err; err; end
    @test e isa ValidationError
    @test occursin("claims_outpatient", e.msg)

    e = try; check_v5_source("hospital-admissions"); nothing; catch err; err; end
    @test occursin("claims_inpatient", e.msg)

    e = try; check_v5_source("fluview"); nothing; catch err; err; end
    @test occursin("fetch_fluview", e.msg)
end

@testset "v5_params" begin
    p = v5_params(; V5_Q...)
    @test p["source"] == "nssp"
    @test p["signal"] == "pct_ed_visits_covid"
    @test p["geo_type"] == "state"
    @test p["format"] == "csv"

    @test !haskey(p, "fill_method")
    @test !haskey(p, "geo_value")
    @test !haskey(p, "time_values")

    @test v5_params(; V5_Q..., snapshot_date = Date(2026, 7, 1))["snapshot_date"] == "2026-07-01"
    @test v5_params(; V5_Q..., snapshot_date = "2026-07-01")["snapshot_date"] == "2026-07-01"
    @test v5_params(; V5_Q..., report_time = Date(2026, 6, 26))["report_time_query"] == "=2026-06-26"

    e = try
        v5_params(source = "nssp", signal = "a,b", geo_type = "state")
        nothing
    catch err
        err
    end
    @test e isa ValidationError
    @test occursin("one signal", e.msg)

    @test_throws ValidationError v5_params(source = "nssp", signal = "pct_ed_visits_covid",
                                           geo_type = "galaxy")
    @test_throws ValidationError v5_params(source = "nssp", signal = "",
                                           geo_type = "state")

    e = try
        v5_params(; V5_Q..., snapshot_date = "202620")
        nothing
    catch err
        err
    end
    @test e isa ValidationError
    @test occursin("YYYY-MM-DD", e.msg)
end

@testset "format_report_time_query" begin
    @test format_report_time_query(Date(2026, 6, 26)) == "=2026-06-26"
    @test format_report_time_query("=2026-06-26") == "=2026-06-26"
    @test format_report_time_query("<2026-06-26") == "<2026-06-26"
    @test format_report_time_query(">2026-06-26") == ">2026-06-26"
    @test format_report_time_query("2026-06-26") == "=2026-06-26"
    @test_throws ValidationError format_report_time_query("~2026-06-26")
    @test_throws ValidationError format_report_time_query("202620")
end

@testset "filter_observations" begin
    mk(geo, ref, fm = :source) = EpiObservation(
        source = :nssp, signal = :pct_ed_visits_covid, geo_level = STATE, geo_id = geo,
        period_start = ref, period_end = ref, value = 1.0, fill_method = fm)

    tbl = StructArray([mk("ca", Date(2026, 1, 1)), mk("ny", Date(2026, 1, 2)),
                       mk("ca", Date(2026, 2, 1)), mk("ca", Date(2026, 1, 1), :ave)])

    @test length(filter_observations(tbl)) == 4
    @test length(filter_observations(tbl; geo_values = "ca")) == 3
    @test length(filter_observations(tbl; geo_values = ["ca", "ny"])) == 4
    @test length(filter_observations(tbl; geo_values = ["CA"])) == 3

    @test length(filter_observations(tbl;
        reference_time = Date(2026, 1, 1):Date(2026, 1, 31))) == 3
    @test length(filter_observations(tbl; reference_time = Date(2026, 2, 1))) == 1
    @test length(filter_observations(tbl;
        reference_time = [Date(2026, 1, 2), Date(2026, 2, 1)])) == 2

    @test length(filter_observations(tbl; fill_method = "ave")) == 1
    @test length(filter_observations(tbl; fill_method = :source)) == 3
    @test length(filter_observations(tbl; fill_method = "fill_ave")) == 1

    @test length(filter_observations(tbl; geo_values = :ca)) == 3

    @test length(filter_observations(tbl;
        reference_time = ["2026-01-02", "2026-02-01"])) == 2
    @test_throws ValidationError filter_observations(tbl; reference_time = "202601")
    @test_throws ValidationError filter_observations(tbl; reference_time = ["3"])
    @test_throws ValidationError filter_observations(tbl; reference_time = 1:10)

    @test length(filter_observations(tbl; geo_values = "ca", fill_method = :source,
                                     reference_time = Date(2026, 1, 1))) == 1

    @test length(filter_observations(tbl; geo_values = "zz")) == 0
    @test filter_observations(tbl; geo_values = "zz") isa EpiTable
end
