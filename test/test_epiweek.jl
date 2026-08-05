using Dates
using EpiDataKit: epiweek, epiweek_start, epiweek_end, year_start, week_start,
                  weeks_in_epiyear, parse_epiweek, parse_epiday, period_bounds, parse_issue

@testset "epiweek" begin
    @testset "published anchors" begin
        # These four are the standard cross-check set: each sits on a year boundary where
        # a naive implementation goes wrong in a different way.
        @test epiweek(Date(2020, 12, 27)) == (2020, 53)
        @test epiweek(Date(2021, 1, 3)) == (2021, 1)
        @test epiweek(Date(2019, 12, 29)) == (2020, 1)   # MMWR year runs ahead of the calendar
        @test epiweek(Date(2025, 12, 31)) == (2025, 53)  # calendar 2026 would be wrong
    end

    @testset "week_start lands on Sunday" begin
        for d in Date(2024, 1, 1):Day(1):Date(2024, 12, 31)
            @test dayofweek(week_start(d)) == 7
            @test 0 <= Dates.value(d - week_start(d)) <= 6
        end
    end

    @testset "year_start opens on Sunday with Wednesday in-year" begin
        for y in 2010:2035
            s = year_start(y)
            @test dayofweek(s) == 7
            @test year(s + Day(3)) == y
        end
    end

    @testset "exhaustive round-trip 2010-2035" begin
        failures = Date[]
        for d in Date(2010, 1, 1):Day(1):Date(2035, 12, 31)
            y, w = epiweek(d)
            epiweek_start(y, w) <= d <= epiweek_end(y, w) || push!(failures, d)
        end
        @test isempty(failures)
    end

    @testset "53-week years" begin
        @test [y for y in 2010:2035 if weeks_in_epiyear(y) == 53] == [2014, 2020, 2025, 2031]
        @test all(weeks_in_epiyear(y) in (52, 53) for y in 1990:2050)
    end

    @testset "the ISO-week shortcut is not equivalent" begin
        # Guards against anyone "simplifying" epiweek into ISO arithmetic later. The two
        # disagree precisely when Dec 31 is a Wednesday.
        d = Date(2025, 12, 31)
        shifted = d + Day(1)
        @test (year(shifted), week(shifted)) == (2026, 1)
        @test epiweek(d) == (2025, 53)
    end

    @testset "parse_epiweek" begin
        @test parse_epiweek(202620) == (2026, 20)
        @test parse_epiweek("202620") == (2026, 20)
        @test parse_epiweek(" 202620 ") == (2026, 20)
        @test parse_epiweek(202053) == (2020, 53)      # 2020 is a long year
        @test_throws ValidationError parse_epiweek(202153)  # 2021 is not
        @test_throws ValidationError parse_epiweek(202600)
    end

    @testset "parse_epiweek rejects wrong-width input" begin
        # Regression: the encoding is fixed-width, and `divrem(n, 100)` will happily read
        # a truncated field as a plausible (year, week). "2026" became (20, 26): year 20 AD,
        # week 26, and produced real Dates that nothing downstream could question.
        # A miscounted digit is the failure that actually happens; week 54 is not.
        @test_throws ValidationError parse_epiweek("2026")
        @test_throws ValidationError parse_epiweek("26")
        @test_throws ValidationError parse_epiweek(2026)
        @test_throws ValidationError parse_epiweek("20262001")
        @test_throws ValidationError parse_epiweek("2026-20")
        @test_throws ValidationError parse_epiweek("abcdef")
        @test_throws ValidationError parse_epiweek(-202620)
        @test_throws ValidationError parse_epiweek(202620.0)  # a float is not the encoding

        # And the error is the package's own type, not whatever `parse` raised.
        for bad in ("2026", "abcdef", "2026-20")
            @test_throws ValidationError period_bounds("week", bad)
            @test_throws ValidationError parse_issue("week", bad)
        end
    end

    @testset "parse_epiday" begin
        @test parse_epiday(20200601) == Date(2020, 6, 1)
        @test parse_epiday("20200601") == Date(2020, 6, 1)
        @test_throws ValidationError parse_epiday(2020601)
    end

    @testset "period_bounds" begin
        @test period_bounds("week", 202620) == (Date(2026, 5, 17), Date(2026, 5, 23))
        @test period_bounds("week", "202620") == (Date(2026, 5, 17), Date(2026, 5, 23))
        @test period_bounds("day", 20200601) == (Date(2020, 6, 1), Date(2020, 6, 1))

        # A weekly interval is always exactly 7 closed days; a daily one collapses.
        ps, pe = period_bounds("week", 202601)
        @test pe - ps == Day(6)
        ps, pe = period_bounds("day", 20260101)
        @test ps == pe

        @test_throws ValidationError period_bounds("month", 202601)
    end

    @testset "parse_issue" begin
        # A weekly issue resolves to the close of the issuing week.
        @test parse_issue("week", 202630) == Date(2026, 8, 1)
        @test parse_issue("day", 20260801) == Date(2026, 8, 1)
        @test parse_issue("week", "") === missing
        @test parse_issue("week", missing) === missing
        @test parse_issue("week", nothing) === missing
    end

    @testset "issue/period gap reproduces the reported lag" begin
        # The success fixture reports time_value=202620, issue=202630, lag=10. If the
        # epiweek conversion is right, the gap between period end and issue is 10 weeks.
        _, pe = period_bounds("week", 202620)
        iss = parse_issue("week", 202630)
        @test Dates.value(iss - pe) == 10 * 7
    end
end
