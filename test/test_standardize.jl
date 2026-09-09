using CSV
using Dates
using StructArrays
using Tables
using EpiDataKit: decode_response, mock_response, standardize, coerce_float,
                  coerce_missing_code, empty_table

@testset "standardize" begin
    src = DelphiCovidcast()
    tbl = standardize(src, decode_response(src, mock_response(fixture("covidcast_success.csv"))))

    @testset "shape and column types" begin
        @test tbl isa EpiTable
        @test length(tbl) == 2
        @test eltype(tbl) == EpiObservation

        @test tbl.source isa Vector{Symbol}
        @test tbl.geo_level isa Vector{GeoLevel}
        @test tbl.geo_id isa Vector{String}
        @test tbl.period_start isa Vector{Date}
        @test tbl.value isa Vector{Union{Float64,Missing}}
        @test tbl.issue isa Vector{Union{Date,Missing}}
        @test tbl.missing_code isa Vector{MissingCode}
    end

    @testset "values decoded from the recorded response" begin
        o = tbl[1]
        @test o.source === :nssp
        @test o.signal === :pct_ed_visits_covid
        @test o.geo_level == STATE
        @test o.geo_id == "ca"
        @test o.value ≈ 0.07
        @test o.missing_code == NOT_MISSING
    end

    @testset "weekly rows become closed 7-day intervals" begin
        for o in tbl
            @test o.period_end - o.period_start == Day(6)
            @test dayofweek(o.period_start) == 7  # Sunday
            @test dayofweek(o.period_end) == 6    # Saturday
        end
        @test tbl[1].period_start == Date(2026, 5, 17)
        @test tbl[2].period_start == Date(2026, 5, 24)
    end

    @testset "issue resolves to the close of the issuing week" begin
        @test all(o -> o.issue == Date(2026, 8, 1), tbl)
        # Publication cannot precede the period it reports.
        @test all(o -> o.issue >= o.period_end, tbl)
    end

    @testset "blank stderr and sample_size become missing" begin
        # The fixture carries missing_stderr=1 and missing_sample_size=1 with empty cells.
        @test all(o -> o.stderr === missing, tbl)
        @test all(o -> o.sample_size === missing, tbl)
    end

    @testset "string-encoded numerics coerce" begin
        # JSON mode returns numbers as strings where CSV mode returns reals; both must
        # land in the same schema.
        rows = [(
            source = "nssp", signal = "pct_ed_visits_covid", geo_type = "state",
            geo_value = "ca", time_type = "week", time_value = "202620",
            issue = "202630", value = "0.07", stderr = "", sample_size = "NA",
            missing_value = "0",
        )]
        t = standardize(src, rows)
        @test length(t) == 1
        @test t[1].value ≈ 0.07
        @test t[1].stderr === missing
        @test t[1].sample_size === missing
        @test t[1].period_start == Date(2026, 5, 17)
        @test t[1].issue == Date(2026, 8, 1)
        @test t[1].missing_code == NOT_MISSING
    end

    @testset "daily signals collapse to a single-day interval" begin
        rows = [(
            source = "jhu-csse", signal = "confirmed_incidence_num", geo_type = "state",
            geo_value = "ca", time_type = "day", time_value = 20200601,
            issue = 20230310, value = 2437.0, stderr = missing,
            sample_size = missing, missing_value = 0,
        )]
        t = standardize(src, rows)
        @test t[1].period_start == t[1].period_end == Date(2020, 6, 1)
        @test t[1].issue == Date(2023, 3, 10)
        @test t[1].value ≈ 2437.0
    end

    @testset "county FIPS survives a numeric column" begin
        rows = [(
            source = "s", signal = "x", geo_type = "county", geo_value = 6075,
            time_type = "day", time_value = 20200601, issue = 20200602,
            value = 1.0, stderr = missing, sample_size = missing, missing_value = 0,
        )]
        @test standardize(src, rows)[1].geo_id == "06075"
    end

    @testset "absent columns are tolerated" begin
        # These payloads omit a key rather than sending an explicit null.
        rows = [(
            source = "s", signal = "x", geo_type = "state", geo_value = "ca",
            time_type = "week", time_value = 202620,
        )]
        t = standardize(src, rows)
        @test t[1].value === missing
        @test t[1].issue === missing
        @test t[1].missing_code == NOT_MISSING
    end

    @testset "row-oriented payloads may omit any key on any row" begin
        json(s) = decode_response(src, mock_response(s))
        row(extra) = """{"geo_value":"ca","signal":"s","source":"n","geo_type":"state","time_type":"week","time_value":202620$extra}"""

        # First row lacks `value`, second carries it.
        t = standardize(src, json("""{"result":1,"epidata":[$(row("")),$(row(",\"value\":1.5"))]}"""))
        @test t[1].value === missing
        @test t[2].value == 1.5

        # First row carries `value`, second lacks it.
        t = standardize(src, json("""{"result":1,"epidata":[$(row(",\"value\":1.5")),$(row(""))]}"""))
        @test t[1].value == 1.5
        @test t[2].value === missing

        # Same for the other optional fields.
        t = standardize(src, json("""{"result":1,"epidata":[$(row("")),$(row(",\"issue\":202630,\"stderr\":0.25,\"missing_value\":3"))]}"""))
        @test t[1].issue === missing
        @test t[2].issue == Date(2026, 8, 1)
        @test t[2].stderr == 0.25
        @test t[2].missing_code == CENSORED
    end

    @testset "identity fields cannot be absent" begin
        # Regression: these went through `Symbol(strip(string(x)))`, so an absent value
        # became the entirely plausible `:missing` / "missing" rather than an error.
        # source, signal and geo_id identify an observation and are non-nullable.
        base = (source = "s", signal = "x", geo_type = "state", geo_value = "ca",
                time_type = "week", time_value = 202620)

        @test_throws ValidationError standardize(src, [Base.structdiff(base, (source = 0,))])
        @test_throws ValidationError standardize(src, [Base.structdiff(base, (signal = 0,))])
        @test_throws ValidationError standardize(src, [merge(base, (source = missing,))])
        @test_throws ValidationError standardize(src, [merge(base, (signal = nothing,))])
        @test_throws ValidationError standardize(src, [merge(base, (source = "  ",))])
        @test_throws ValidationError standardize(src, [merge(base, (geo_value = missing,))])
        @test_throws ValidationError standardize(src, [merge(base, (geo_value = nothing,))])

        # The valid row still works, so the guard is not simply rejecting everything.
        @test standardize(src, [base])[1].source === :s
    end

    @testset "missingness codes map through" begin
        for (code, expected) in [(0, NOT_MISSING), (1, NOT_APPLICABLE), (2, REGION_EXCEPTION),
                                 (3, CENSORED), (4, DELETED), (5, OTHER)]
            rows = [(
                source = "s", signal = "x", geo_type = "state", geo_value = "ca",
                time_type = "week", time_value = 202620, issue = 202630,
                value = missing, stderr = missing, sample_size = missing,
                missing_value = code,
            )]
            @test standardize(src, rows)[1].missing_code == expected
        end
    end
end

@testset "coercion helpers" begin
    @testset "coerce_float" begin
        @test coerce_float(1.5) === 1.5
        @test coerce_float(2) === 2.0
        @test coerce_float("1.5") === 1.5
        @test coerce_float(" 1.5 ") === 1.5
        @test coerce_float("") === missing
        @test coerce_float("NA") === missing
        @test coerce_float("null") === missing
        @test coerce_float(missing) === missing
        @test coerce_float(nothing) === missing
        @test coerce_float("garbage") === missing
        @test coerce_float(NaN) === missing
        @test coerce_float("NaN") === missing
    end

    @testset "coerce_missing_code" begin
        @test coerce_missing_code(0) == NOT_MISSING
        @test coerce_missing_code("3") == CENSORED
        @test coerce_missing_code(missing) == NOT_MISSING
        @test coerce_missing_code(nothing) == NOT_MISSING
        @test coerce_missing_code("") == NOT_MISSING
        # An unrecognized code should not break otherwise-fine rows.
        @test coerce_missing_code(99) == OTHER
        @test coerce_missing_code(-4) == OTHER
        @test coerce_missing_code("garbage") == OTHER
    end
end

@testset "lag is kept in the source's own units" begin
    # `issue - period_end` is in days whatever the resolution, and the schema does not
    # record the resolution, so a derived lag would be 7x off for weekly signals with no
    # way to notice. The fixture reports lag=10 for a weekly row spanning 70 days.
    src = DelphiCovidcast()
    tbl = standardize(src, decode_response(src, mock_response(fixture("covidcast_success.csv"))))
    @test tbl.lag == [10, 9]
    @test Dates.value(tbl.issue[1] - tbl.period_end[1]) == 10 * 7

    fv = DelphiFluView()
    flu = standardize(fv, decode_response(fv, mock_response(fixture("fluview_success.json"))))
    @test all(==(72), flu.lag[flu.period_start .== Date(2020, 5, 10)])

    # Absent rather than zero when the row carries no lag.
    header = split(fixture("covidcast_success.csv"), '\n')[1]
    body = header * "\nca,x,s,state,week,202620,,202630,,0,0,0,1.0,,\n"
    @test standardize(src, decode_response(src, mock_response(body))).lag[1] === missing
end

@testset "EpiObservation equality" begin
    mk(v) = EpiObservation(source = :s, signal = :x, geo_level = STATE, geo_id = "ca",
                           period_start = Date(2026, 5, 17), period_end = Date(2026, 5, 23),
                           value = v, issue = Date(2026, 8, 1), lag = 10,
                           missing_code = NOT_MISSING)

    # `==` on a struct holding `missing` would otherwise propagate `missing` instead of
    # answering, which would make observations impossible to compare or deduplicate.
    @test mk(missing) == mk(missing)
    @test isequal(mk(missing), mk(missing))
    @test mk(1.0) == mk(1.0)
    @test mk(1.0) != mk(2.0)
    @test mk(1.0) != mk(missing)

    @test hash(mk(missing)) == hash(mk(missing))
    @test length(Set([mk(1.0), mk(1.0), mk(2.0)])) == 2
end

@testset "empty_table" begin
    e = empty_table()
    @test e isa EpiTable
    @test length(e) == 0
    @test eltype(e) == EpiObservation
end

@testset "schema v2 fields" begin
    o = EpiObservation(
        source = :nssp, signal = :pct_ed_visits_covid, geo_level = STATE, geo_id = "ca",
        period_start = Date(2026, 5, 17), period_end = Date(2026, 5, 23),
        value = 0.07,
    )
    @test o.fill_method === :source
    @test o.ci_lower === missing
    @test o.ci_upper === missing
    @test o.stderr === missing
    @test o.missing_code === NOT_MISSING
    @test fieldcount(EpiObservation) == 15

    p = EpiObservation(:nssp, :pct_ed_visits_covid, STATE, "ca",
                       Date(2026, 5, 17), Date(2026, 5, 23),
                       0.07, missing, missing, missing, missing,
                       missing, missing, :source, NOT_MISSING)
    @test o == p
    @test hash(o) == hash(p)

    body = "geo_value,signal,source,geo_type,time_type,time_value,direction,issue,lag," *
           "missing_value,missing_stderr,missing_sample_size,value,stderr,sample_size\n" *
           "ca,pct_ed_visits_covid,nssp,state,week,202620,,202630,10,0,1,1,0.07,,\n"
    tbl = standardize(DelphiCovidcast(), CSV.File(IOBuffer(body);
                      types = Dict("geo_value" => String), stringtype = String))
    @test only(tbl.fill_method) === :source
    @test only(tbl.ci_lower) === missing
end
