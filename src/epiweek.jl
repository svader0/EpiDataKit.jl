# MMWR ("epi") weeks — the calendar US public health surveillance is reported on.
#
# Definition: weeks run Sunday through Saturday. Week 1 of a given MMWR year is the first
# such week with at least four days in that calendar year, which is equivalently the week
# whose *Wednesday* falls in that year. A year therefore has 52 or 53 weeks, and the first
# few days of January frequently belong to the previous MMWR year.
#
# The tempting shortcut is "MMWR week == ISO week of `d + 1 day`". It is wrong. ISO weeks
# pivot on Thursday; shifting by a day moves that pivot to Wednesday, which looks right,
# but the two disagree about which *year* owns the week whenever Dec 31 is a Wednesday.
# For 2025-12-31 the shortcut yields (2026, 1) where the answer is (2025, 53). Computing
# it directly is barely more code and is not subtly wrong.

"""
    week_start(d::Date) -> Date

The Sunday that opens the MMWR week containing `d`. Returns `d` itself when `d` is a Sunday.
"""
week_start(d::Date) = d - Day(mod(dayofweek(d), 7))  # dayofweek: Mon=1 … Sun=7

"""
    year_start(y::Integer) -> Date

The Sunday that opens MMWR year `y`, i.e. the start of its week 1.

This can fall in the previous calendar year — MMWR 2021 opens on 2021-01-03, but MMWR
2020 opens on 2019-12-29.
"""
function year_start(y::Integer)
    s = week_start(Date(y, 1, 1))
    # Week 1 is the one whose Wednesday (start + 3 days) lands in year `y`. If the week
    # containing Jan 1 fails that test it belongs to the prior year, so step forward one.
    return year(s + Day(3)) == y ? s : s + Day(7)
end

"""
    epiweek(d::Date) -> (year, week)

The MMWR year and week number containing `d`.

The year returned is the *MMWR* year, which near a year boundary need not match
`Dates.year(d)`:

```jldoctest
julia> using EpiDataKit: epiweek

julia> epiweek(Date(2019, 12, 29))
(2020, 1)

julia> epiweek(Date(2025, 12, 31))
(2025, 53)
```
"""
function epiweek(d::Date)
    y = year(d)
    s = week_start(d)
    # `d`'s calendar year is the right starting guess, but the week can spill either way
    # across the boundary. At most one nudge is ever needed.
    s < year_start(y) && (y -= 1)
    s >= year_start(y + 1) && (y += 1)
    return (y, Int(div(Dates.value(s - year_start(y)), 7)) + 1)
end

"""
    epiweek_start(y::Integer, w::Integer) -> Date

The Sunday opening MMWR week `w` of year `y`.
"""
epiweek_start(y::Integer, w::Integer) = year_start(y) + Day(7 * (w - 1))

"""
    epiweek_end(y::Integer, w::Integer) -> Date

The Saturday closing MMWR week `w` of year `y`.
"""
epiweek_end(y::Integer, w::Integer) = epiweek_start(y, w) + Day(6)

"""
    weeks_in_epiyear(y::Integer) -> Int

Number of MMWR weeks in year `y`: 52, or 53 in a long year (2014, 2020, 2025, 2031, …).
"""
weeks_in_epiyear(y::Integer) = Int(div(Dates.value(year_start(y + 1) - year_start(y)), 7))

"""
    parse_epiweek(x) -> (year, week)

Split Delphi's packed `YYYYWW` epiweek encoding, accepting either an integer or its
string form.

Both halves of the encoding are checked. The width must be exactly six digits, because
the failure that actually happens is a truncated or over-long field, not a fanciful week
54 — and `divrem(n, 100)` is happy to read `"2026"` as year 20 week 26 and hand back real
dates in the year 20 AD. The week number must then exist in that year, since a decode
that lands on week 53 of a 52-week year is wrong by a whole year.
"""
function parse_epiweek(x)
    s = strip(string(x))
    if length(s) != 6 || !all(isdigit, s)
        throw(ValidationError(
            "invalid epiweek $(repr(String(s))): expected exactly 6 digits YYYYWW"))
    end
    n = parse(Int, s)
    y, w = divrem(n, 100)
    if w < 1 || w > weeks_in_epiyear(y)
        throw(ValidationError("invalid epiweek $n: year $y has $(weeks_in_epiyear(y)) weeks"))
    end
    return (y, w)
end

"""
    parse_epiday(x) -> Date

Parse Delphi's packed `YYYYMMDD` daily encoding, accepting either an integer or its
string form.
"""
function parse_epiday(x)
    s = strip(string(x))
    length(s) == 8 || throw(ValidationError("invalid date $s: expected 8 digits YYYYMMDD"))
    return Date(s, dateformat"yyyymmdd")
end

"""
    period_bounds(time_type, time_value) -> (period_start, period_end)

Convert one of Delphi's packed time values into the closed interval it denotes.

`"day"` values become a single-day interval; `"week"` values span the MMWR week. This is
the one place the two time encodings are reconciled, so everything downstream sees
intervals and never has to branch on resolution.
"""
function period_bounds(time_type::AbstractString, time_value)
    tt = lowercase(strip(time_type))
    if tt == "day"
        d = parse_epiday(time_value)
        return (d, d)
    elseif tt == "week"
        y, w = parse_epiweek(time_value)
        return (epiweek_start(y, w), epiweek_end(y, w))
    else
        throw(ValidationError("unsupported time_type $(repr(time_type)); expected \"day\" or \"week\""))
    end
end

"""
    parse_issue(time_type, issue) -> Union{Date,Missing}

Convert an `issue` field to the date the value was published.

`issue` follows the same encoding as the signal's own time axis, so a weekly signal
issues on epiweeks, not calendar dates. Weekly issues resolve to the *end* of the issuing
week: publication cannot precede the period it reports, so the closing Saturday is the
tightest defensible bound.
"""
function parse_issue(time_type::AbstractString, issue)
    (issue === missing || issue === nothing) && return missing
    issue isa AbstractString && isempty(strip(issue)) && return missing
    tt = lowercase(strip(time_type))
    if tt == "day"
        return parse_epiday(issue)
    elseif tt == "week"
        y, w = parse_epiweek(issue)
        return epiweek_end(y, w)
    else
        throw(ValidationError("unsupported time_type $(repr(time_type)) for issue $(issue)"))
    end
end
