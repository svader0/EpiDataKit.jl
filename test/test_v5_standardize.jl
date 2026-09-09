using Dates
using EpiDataKit: DelphiV5, decode_v5, infer_time_type, standardize, mock_response,
                  V5_KEY_HEADER, coerce_date

@testset "infer_time_type" begin
    @test infer_time_type([Date(2022, 10, 1), Date(2022, 10, 8), Date(2022, 10, 15)]) === :week
    @test infer_time_type([Date(2019, 10, 8), Date(2019, 10, 9)]) === :day

    # A gap in the middle must not change the answer. The smallest positive gap decides.
    @test infer_time_type([Date(2022, 10, 1), Date(2022, 10, 8), Date(2022, 10, 29)]) === :week
    @test infer_time_type([Date(2019, 10, 8), Date(2019, 10, 9), Date(2019, 11, 1)]) === :day

    # Unsorted and duplicated input still works.
    @test infer_time_type([Date(2022, 10, 8), Date(2022, 10, 1), Date(2022, 10, 8)]) === :week

    # Too little to tell: fall back to daily.
    @test infer_time_type([Date(2022, 10, 1)]) === :day
    @test infer_time_type(Date[]) === :day
end

@testset "coerce_date" begin
    @test coerce_date("2026-06-26") == Date(2026, 6, 26)
    @test coerce_date("2026-09-07T19:10:00") == Date(2026, 9, 7)
    @test coerce_date(Date(2026, 6, 26)) == Date(2026, 6, 26)
    @test coerce_date(DateTime(2026, 6, 26, 12)) == Date(2026, 6, 26)
    @test coerce_date(missing) === missing
    @test coerce_date("") === missing
end

@testset "standardize DelphiV5" begin
    @testset "a weekly source" begin
        body = V5_KEY_HEADER * ",value\n" *
               "pct_ed_visits_covid,2026-06-26,state,ak,source,2022-10-01,1.61\n" *
               "pct_ed_visits_covid,2026-06-26,state,ak,source,2022-10-08,1.31\n"
        tbl = standardize(DelphiV5(:nssp), decode_v5(mock_response(body)))

        @test length(tbl) == 2
        @test tbl[1].source === :nssp
        @test tbl[1].signal === :pct_ed_visits_covid
        @test tbl[1].geo_level == STATE
        @test tbl[1].geo_id == "ak"
        # reference_time is the MMWR week-ending Saturday.
        @test tbl[1].period_end == Date(2022, 10, 1)
        @test tbl[1].period_start == Date(2022, 9, 25)
        @test tbl[1].period_end - tbl[1].period_start == Day(6)
        @test tbl[1].issue == Date(2026, 6, 26)
        @test tbl[1].value ≈ 1.61
        @test tbl[1].fill_method === :source
        @test tbl[1].stderr === missing
        @test tbl[1].ci_lower === missing
        @test tbl[1].missing_code === NOT_MISSING
        # lag counts whole weeks for a weekly signal.
        @test tbl[1].lag == div(Dates.value(Date(2026, 6, 26) - Date(2022, 10, 1)), 7)
    end

    @testset "a daily source" begin
        body = V5_KEY_HEADER * ",value\n" *
               "claims_outpatient_ov_pct_claims_covid,2026-09-07,county,06075,source,2019-10-08,0.5\n" *
               "claims_outpatient_ov_pct_claims_covid,2026-09-07,county,06075,source,2019-10-09,0.6\n"
        tbl = standardize(DelphiV5(:claims_outpatient), decode_v5(mock_response(body)))

        @test tbl[1].period_start == tbl[1].period_end == Date(2019, 10, 8)
        @test tbl[1].geo_id == "06075"
        @test tbl[1].lag == Dates.value(Date(2026, 9, 7) - Date(2019, 10, 8))
    end

    @testset "fill_method is kept, so aggregated rows do not collide" begin
        body = V5_KEY_HEADER * ",value\n" *
               "pct_ed_visits_covid,2026-06-26,hhs,1,zero,2022-10-01,3.25\n" *
               "pct_ed_visits_covid,2026-06-26,hhs,1,ave,2022-10-01,3.26\n" *
               "pct_ed_visits_covid,2026-06-26,hhs,1,zero,2022-10-08,3.30\n"
        tbl = standardize(DelphiV5(:nssp), decode_v5(mock_response(body)))

        @test Set(tbl.fill_method) == Set([:zero, :ave])
        @test length(unique(collect(tbl))) == 3
        @test tbl[1].geo_level == HHS_REGION
    end

    @testset "ci bounds are carried" begin
        body = V5_KEY_HEADER * ",ci_lower,ci_upper,value\n" *
               "pct_cough_2_plus_7dav,2026-04-10,state,al,source,2023-01-07,10.6,15.5,12.9\n" *
               "pct_cough_2_plus_7dav,2026-04-10,state,al,source,2023-01-08,10.7,15.4,13.0\n"
        tbl = standardize(DelphiV5(:sleepcycle), decode_v5(mock_response(body)))

        @test tbl[1].ci_lower ≈ 10.6
        @test tbl[1].ci_upper ≈ 15.5
        @test tbl[1].value ≈ 12.9
        @test tbl[1].sample_size === missing
    end

    @testset "an absent value keeps the row and records that the reason is unknown" begin
        body = V5_KEY_HEADER * ",value\n" *
               "pct_ed_visits_covid,2026-06-26,state,ak,source,2022-10-01,\n" *
               "pct_ed_visits_covid,2026-06-26,state,ak,source,2022-10-08,1.31\n"
        tbl = standardize(DelphiV5(:nssp), decode_v5(mock_response(body)))

        @test length(tbl) == 2
        @test tbl[1].value === missing
        @test tbl[1].missing_code === OTHER
        @test tbl[2].missing_code === NOT_MISSING
    end

    @testset "a report_time with a clock time still gives a date" begin
        body = V5_KEY_HEADER * ",value\n" *
               "claims_outpatient_ov_pct_claims_covid,2026-09-07T19:10:00,state,ca,source,2019-10-08,0.5\n" *
               "claims_outpatient_ov_pct_claims_covid,2026-09-07T19:10:00,state,ca,source,2019-10-09,0.6\n"
        tbl = standardize(DelphiV5(:claims_outpatient), decode_v5(mock_response(body)))
        @test tbl[1].issue == Date(2026, 9, 7)
    end

    @testset "the caller can override the inferred resolution" begin
        body = V5_KEY_HEADER * ",value\n" *
               "pct_ed_visits_covid,2026-06-26,state,ak,source,2022-10-01,1.61\n"
        tbl = @test_logs standardize(DelphiV5(:nssp), decode_v5(mock_response(body));
                                     time_type = "week")
        @test tbl[1].period_start == Date(2022, 9, 25)

        # Without the override a single row falls back to daily.
        tbl2 = @test_logs (:warn,) match_mode = :any standardize(DelphiV5(:nssp),
                                                                 decode_v5(mock_response(body)))
        @test tbl2[1].period_start == Date(2022, 10, 1)
    end

    @testset "a row with no report_time has a missing issue and lag" begin
        body = V5_KEY_HEADER * ",value\n" *
               "pct_ed_visits_covid,,state,ak,source,2022-10-01,1.61\n" *
               "pct_ed_visits_covid,,state,ak,source,2022-10-08,1.31\n"
        tbl = standardize(DelphiV5(:nssp), decode_v5(mock_response(body)))
        @test tbl[1].issue === missing
        @test tbl[1].lag === missing
    end
end
