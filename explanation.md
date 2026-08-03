# EpiDataKit, explained piece by piece

A walkthrough of every type, constant, and function in the package — what it is, what it
does, and why it exists. Written for someone who wants to be able to defend every line.

Files appear in the order they load, so nothing depends on a concept you haven't met yet.

---

## Contents

1. [The 30-second version](#the-30-second-version)
2. [Julia concepts you'll need](#julia-concepts-youll-need)
3. [`src/EpiDataKit.jl`](#srcepidatakitjl--the-front-door)
4. [`src/types.jl`](#srctypesjl--the-vocabulary)
5. [`src/arrowtypes.jl`](#srcarrowtypesjl--teaching-arrow-about-enums)
6. [`src/epiweek.jl`](#srcepiweekjl--the-public-health-calendar)
7. [`src/geo.jl`](#srcgeojl--place-identifiers)
8. [`src/transport.jl`](#srctransportjl--the-network-boundary)
9. [`src/standardize.jl`](#srcstandardizejl--messy-input-clean-table)
10. [`src/sources/delphi.jl`](#srcsourcesdelphijl--speaking-delphi)
11. [`src/store.jl`](#srcstorejl--onto-disk-and-back)
12. [`test/`](#test--how-it-is-checked)
13. [`bench/`](#bench--the-numbers)
14. [Questions you might get asked](#questions-you-might-get-asked)

---

## The 30-second version

You ask for a public health statistic. The package fetches it from Delphi's server,
untangles the mess it arrives in, and writes it to disk in a format that other programs
can read almost instantly.

```
   fetch_signal(...)
        │
        ├─ 1. EXTRACT   transport.jl      get bytes over HTTP
        │               sources/delphi.jl figure out if those bytes are data or an error
        │
        ├─ 2. TRANSFORM standardize.jl    turn them into one uniform table
        │               epiweek.jl        (fix the dates)
        │               geo.jl            (fix the place names)
        │
        └─ 3. LOAD      store.jl          write/read Arrow files
```

Everything else is vocabulary (`types.jl`) or glue (`arrowtypes.jl`).

---

## Julia concepts you'll need

Skim this; refer back when something looks strange.

| Thing | Means |
|---|---|
| `x::Int` | "x must be an Int." On a function argument this also picks *which version* of the function runs. |
| `Union{Float64,Missing}` | "either a number or explicitly absent." A type that is one of several options. |
| `missing` | A real value meaning "we don't know." Not the same as `nothing`. |
| `nothing` | Means "there is nothing here at all" — usually a function that returns no answer. |
| `:nssp` | A `Symbol`. Like a string, but interned — cheap to compare, used as a label rather than as text. |
| `struct` | A record type. Immutable by default: once built, fields can't change. |
| `@enum` | A fixed set of named values, stored as numbers. |
| `abstract type` | A category with no data of its own. Used to group related types. |
| `f.(xs)` | The dot means **broadcast**: apply `f` to every element. |
| `sizehint!` | The `!` is convention for "this modifies its argument." |
| `_helper` | Leading underscore is convention for "internal, don't rely on this." |
| `"""..."""` above a definition | A docstring. Shows up in the REPL with `?name`. |
| `f(a; b = 1)` | Everything after `;` is a **keyword argument**, passed by name. |
| `mktempdir() do dir ... end` | A `do` block. Runs the body with `dir` set, and cleans up afterwards even if it errors. |
| `const X = ...` | A value that won't be reassigned. Lets Julia optimise, and signals intent. |

### Multiple dispatch, in one paragraph

In most languages a function has one body. In Julia, one *name* can have many **methods**,
and Julia picks based on the types of **all** the arguments. So `coerce_float("1.5")` and
`coerce_float(1.5)` run completely different code, chosen automatically. You'll see this
used two ways here: for tidy type-handling (`coerce_float`) and as a plug-in mechanism
(`standardize`, `fetch_raw`).

---

## `src/EpiDataKit.jl` — the front door

The entry point. Julia *requires* this file to be named after the package.

```julia
module EpiDataKit
using Dates, Arrow, CSV, HTTP, JSON3, StructArrays, Tables
using Base64: base64encode

include("types.jl")
include("arrowtypes.jl")
...
export EpiObservation, fetch_signal, ...
end
```

**`module ... end`** — a namespace. Everything defined inside belongs to `EpiDataKit`.

**`using X`** — pull in another package's public names.

**`using Base64: base64encode`** — pull in *only* that one function. Narrower than `using
Base64`, so it's obvious where the name came from.

**`include("...")`** — literally pastes that file in at this point. The order matters:
`types.jl` first because everything else refers to its types.

**`export`** — names a user gets automatically after `using EpiDataKit`. Anything not
exported is still reachable as `EpiDataKit.thing`; it's just not forced into their
namespace.

Note what's *not* exported: `save` and `load`. Those names already exist in Julia's `Base`,
so exporting them would clash. Users write `EpiDataKit.save(...)` — slightly more typing,
zero surprises.

---

## `src/types.jl` — the vocabulary

Defines the nouns. Almost no behaviour here.

### `GeoLevel`

```julia
@enum GeoLevel::Int8 begin
    NATION = 0
    HHS_REGION = 1
    ...
    HSA_NCI = 8
end
```

**What:** the eight geographic resolutions data can arrive at — a whole country, a state, a
county, a media market, and so on.

**Why an enum instead of strings:** if you pass `"state"` around, a typo like `"State"`
silently fails to match. With `STATE`, a typo is an error the moment you run it.

**Why `::Int8`:** each value is stored as one byte. That's what makes this column tiny on
disk later.

**Why the numbers are written out explicitly:** they get written into Arrow files. If you
ever reordered the list, every file written before the change would decode to the wrong
geography — silently. Adding new ones at the end is safe; renumbering is not.

### `MissingCode`

```julia
@enum MissingCode::Int8 begin
    NOT_MISSING = 0
    NOT_APPLICABLE = 1
    REGION_EXCEPTION = 2
    CENSORED = 3
    DELETED = 4
    OTHER = 5
end
```

**What:** *why* a value is absent, not just that it is.

- `NOT_MISSING` — the value is fine, nothing's wrong.
- `NOT_APPLICABLE` — this field can't exist here (e.g. a standard error for a signal that
  isn't a sample).
- `REGION_EXCEPTION` — this indicator doesn't cover this place.
- `CENSORED` — withheld for privacy, usually because the count is too small.
- `DELETED` — it used to be published and has been withdrawn.
- `OTHER` — absent for some other reason.

**Why it matters:** "censored for privacy" means a small non-zero number exists. "Not
applicable" means no number ever could. Most tools flatten both to a blank cell and throw
away that distinction. These numbers are Delphi's, not ours, so they can't be renumbered.

### `EpiObservation`

```julia
struct EpiObservation
    source::Symbol
    signal::Symbol
    geo_level::GeoLevel
    geo_id::String
    period_start::Date
    period_end::Date
    value::Union{Float64,Missing}
    stderr::Union{Float64,Missing}
    sample_size::Union{Float64,Missing}
    issue::Union{Date,Missing}
    missing_code::MissingCode
end
```

**What:** one measurement — one number, for one place, over one stretch of time.

Field by field:

| Field | Meaning |
|---|---|
| `source` | who produced it (`:nssp`, `:nhsn`) |
| `signal` | what was measured (`:pct_ed_visits_covid`) |
| `geo_level` | what *kind* of place |
| `geo_id` | which place (`"ca"`, `"06075"`) |
| `period_start` / `period_end` | the time span it covers, inclusive at both ends |
| `value` | the number |
| `stderr` | uncertainty, when the signal is survey-based |
| `sample_size` | how many responses it came from |
| `issue` | when it was **published** |
| `missing_code` | why `value` is absent, if it is |

**Two decisions worth being able to defend:**

**Why two date fields instead of one date plus a "daily or weekly?" flag.** Delphi has
both. With a flag, every single piece of downstream code has to check it before doing
anything. With a span, a daily observation is just a span where both ends are the same
day — and the check disappears from everyone's code, because the data already answers the
question.

**Why `issue` exists.** This is the genuinely epidemiological part. Surveillance numbers
get **revised**. Last week's case count isn't final; it grows as late reports arrive. So
"the value for week 20" isn't a number — it's a number that changed over time.

`issue` records when a value was published, so a measurement is identified by
`(period_start, issue)`, not `period_start` alone.

Why care? If you're testing a forecasting model, you must feed it what was knowable *at
the time*. Use today's cleaned-up numbers and your model looks brilliant because it was
quietly shown the answers. This field is what makes honest evaluation possible.

**What's deliberately missing:** Delphi sends a `lag` field. It's `issue - period_end` by
definition, so storing it means storing the same fact twice — and two copies of one fact
can disagree. It's dropped, and derived when needed.

### `==`, `isequal`, and `hash` for `EpiObservation`

```julia
Base.:(==)(a::EpiObservation, b::EpiObservation) = isequal(a, b)
Base.isequal(a, b) = all(isequal(getfield(a,f), getfield(b,f)) for f in fieldnames(EpiObservation))
Base.hash(o, h) = foldr(...)
```

**The problem:** in Julia, `missing == missing` gives `missing`, not `true`. That's correct
for statistics — "is one unknown equal to another unknown?" genuinely has no answer. But it
means comparing two records that both have a missing value returns `missing` instead of
yes-or-no, and you can't put them in a `Set` or deduplicate them.

**The fix:** `isequal` is Julia's other comparison, and it treats two absences as the same
absence. For a *record*, that's what you want. So `==` is redirected to it.

**`hash` must agree.** Julia's rule: if two things are equal, they must hash the same, or
`Dict` and `Set` break in confusing ways. `foldr` just combines every field's hash into one.

**`Base.` prefix:** these are Julia's own functions being taught about our type — not new
functions.

### `EpiTable`

```julia
const EpiTable = StructArray{EpiObservation}
```

**What:** a nickname for "a table of observations."

**The clever bit:** a `StructArray` *looks* like a list of records but is *stored* as one
array per field. Instead of a million small objects scattered in memory, you get eleven
long columns.

```
Vector{EpiObservation}:  [rec1][rec2][rec3]...     ← row-major
StructArray:             source:  [:nssp, :nssp, ...]   ← column-major
                         value:   [0.07, 0.06, ...]
```

**Why:** Arrow is a columnar format. Writing a StructArray hands over vectors that already
exist. Writing a `Vector{EpiObservation}` would require transposing a million rows first,
every single time.

It still indexes as rows — `tbl[3]` gives you an `EpiObservation` — so you don't pay for
this in ergonomics.

### `AbstractSource` and `DelphiCovidcast`

```julia
abstract type AbstractSource end
struct DelphiCovidcast <: AbstractSource end
```

**What:** `DelphiCovidcast` is an **empty struct** — no fields, no data. Its only job is to
exist as a type so functions can dispatch on it.

Think of it as a label you hand to a function to say "treat this as covidcast data." When
`fluview` is added, `DelphiFluView` becomes a second label, and `standardize` grows a second
method. `<:` means "is a kind of."

### `EpiDataKitError` and friends

```julia
abstract type EpiDataKitError <: Exception end
struct ValidationError       <: EpiDataKitError; msg::String; end
struct NoResultsError        <: EpiDataKitError; ... end
struct TruncatedResultsError <: EpiDataKitError; ... end
struct EpidataError          <: EpiDataKitError; ... end
struct TransportError        <: EpiDataKitError; ... end
```

**What each means:**

| Error | Meaning |
|---|---|
| `ValidationError` | Your request was wrong and we caught it before sending |
| `NoResultsError` | Valid query, understood fine, but nothing matched |
| `TruncatedResultsError` | The server capped the results — what you got is incomplete |
| `EpidataError` | The server reported a failure in its own format |
| `TransportError` | Something broke below the API's error protocol (404 page, proxy error) |

**Why five types instead of one message string:** so callers can respond differently.
"No data for this week" is often fine; "the server is down" isn't. With distinct types
you write `catch e; if e isa NoResultsError`. The shared parent means you can also catch
everything from this package at once.

### `scrub_secrets(s)`

```julia
function scrub_secrets(s::AbstractString)
    out = replace(s, r"(?i)\b(api_key|apikey|auth|token|password)=[^&\s]*" => s"\1=[REDACTED]")
    replace(out, r"(?i)(https?://)[^/@\s]+:[^/@\s]+@" => s"\1[REDACTED]@")
end
```

**What:** finds anything credential-shaped in a string and blanks it out.

The first pattern catches `api_key=abc123` in a query string. The second catches
`https://user:password@host`. `r"..."` is a regex, `(?i)` makes it case-insensitive, and
`s"\1=[REDACTED]"` keeps the captured name while replacing the value.

**Why:** every error constructor calls this. Exceptions get logged, printed to terminals,
and pasted into bug reports. A key that reaches one should be assumed leaked.

This is defence in depth — the real protection is that the key travels in a header, not the
URL. This catches hand-built URLs that bypass that.

### `showerror` methods

```julia
Base.showerror(io::IO, e::TruncatedResultsError) = print(io, "...", "  hint: narrow the time window...")
```

**What:** controls how each error prints.

**Why bother:** a raw struct dump is unreadable. These print the request, the server's own
message, and — for the truncation case — what to actually do about it. Error messages are
documentation that appears exactly when it's needed.

---

## `src/arrowtypes.jl` — teaching Arrow about enums

The whole file:

```julia
for T in (GeoLevel, MissingCode)
    @eval ArrowTypes.ArrowKind(::Type{$T}) = ArrowTypes.PrimitiveKind()
    @eval ArrowTypes.ArrowType(::Type{$T}) = Int8
    @eval ArrowTypes.toarrow(x::$T) = Int8(x)
    @eval ArrowTypes.fromarrow(::Type{$T}, x::Int8) = $T(x)
end
```

**The problem:** Arrow is a cross-language format. It has no idea what a Julia `@enum` is.

**The fix:** four small declarations telling Arrow "treat this as a plain byte."

- `ArrowKind` — what category of thing this is (a simple scalar).
- `ArrowType` — what it becomes on disk (`Int8`).
- `toarrow` — how to convert going out.
- `fromarrow` — how to convert coming back.

**`for T in (...)` + `@eval`:** writes the same four definitions for both enums without
copy-pasting. `@eval` generates code; `$T` substitutes the actual type in.

**What's deliberately absent, and this is the interesting part.** There's a fifth
declaration available — `arrowname` — that registers an *extension name*. It would make
Arrow round-trip the enum automatically. It's not used, because it stamps a `JuliaLang.*`
tag into the file that readers in other languages have to know to ignore. Leaving it off
means a Go or Python user reads plain integers and needs nothing from this package.

**The price:** without that tag, Arrow doesn't know to call `fromarrow` on the way back, so
it returns raw `Int8`. `load` in `store.jl` converts explicitly. That's a deliberate trade:
slightly more work on our side, zero work for everyone else.

---

## `src/epiweek.jl` — the public health calendar

US public health doesn't use normal weeks. It uses **MMWR weeks** (also called epi weeks):

- Weeks run **Sunday to Saturday**.
- Week 1 of a year is the first week with **at least 4 days** in that year.

The consequence: MMWR years don't line up with calendar years. `2019-12-29` is in **MMWR
year 2020**. And some years have **53** weeks.

### `week_start(d)`

```julia
week_start(d::Date) = d - Day(mod(dayofweek(d), 7))
```

**What:** given any date, walk back to the Sunday that starts its week.

**How:** Julia numbers days Monday=1 … Sunday=7. `mod(7, 7)` is 0, so a Sunday stays put; a
Monday (1) goes back 1 day; a Saturday (6) goes back 6. Neat trick — `mod` handles the
wraparound with no `if`.

### `year_start(y)`

```julia
function year_start(y::Integer)
    s = week_start(Date(y, 1, 1))
    return year(s + Day(3)) == y ? s : s + Day(7)
end
```

**What:** the Sunday that opens MMWR year `y`.

**How:** find the week containing January 1st. Then check its **Wednesday** (`+ Day(3)`
from Sunday). If the Wednesday is in year `y`, that's week 1. If not, week 1 is the next
one.

**Why Wednesday:** "at least 4 days in the year" and "its Wednesday is in the year" are the
same statement — Wednesday is the middle day, so it's in the majority side. Much easier to
compute than counting days.

**`? :`** is if-then-else in expression form.

### `epiweek(d)`

```julia
function epiweek(d::Date)
    y = year(d)
    s = week_start(d)
    s < year_start(y)     && (y -= 1)
    s >= year_start(y + 1) && (y += 1)
    return (y, Int(div(Dates.value(s - year_start(y)), 7)) + 1)
end
```

**What:** the headline function. Date in, `(mmwr_year, week_number)` out.

**How:** guess that the MMWR year matches the calendar year, then correct. If this week
starts before year `y` began, it belongs to `y-1`. If it starts on or after `y+1` began, it
belongs to `y+1`. At most one nudge is ever needed. Then count weeks from the year's start
and add 1 (because weeks are numbered from 1, not 0).

**`cond && (x -= 1)`** is Julia shorthand for "if cond, do this."

**Why this is written longhand.** There's a tempting shortcut: "MMWR week = ISO week of
`date + 1 day`." It's *almost* right and fails when December 31st is a Wednesday. For
`2025-12-31` the shortcut says `(2026, 1)`; the truth is `(2025, 53)`. There's a test
guarding against anyone "simplifying" it back.

### `epiweek_start(y, w)` and `epiweek_end(y, w)`

```julia
epiweek_start(y, w) = year_start(y) + Day(7 * (w - 1))
epiweek_end(y, w)   = epiweek_start(y, w) + Day(6)
```

**What:** the inverse — week number in, actual dates out. Start of the year, plus 7 days per
week elapsed. The end is six days after the start (Sunday + 6 = Saturday).

### `weeks_in_epiyear(y)`

```julia
weeks_in_epiyear(y) = Int(div(Dates.value(year_start(y + 1) - year_start(y)), 7))
```

**What:** 52 or 53. Measures the gap between this year's start and next year's, divided
by 7. `Dates.value` turns a duration into a plain number of days.

**Used for:** validation. Rejecting "week 53" in a year that only has 52 catches decoding
bugs.

### `parse_epiweek(x)`

```julia
function parse_epiweek(x)
    n = x isa Integer ? Int(x) : parse(Int, strip(string(x)))
    y, w = divrem(n, 100)
    if w < 1 || w > weeks_in_epiyear(y)
        throw(ValidationError("invalid epiweek $n: year $y has $(weeks_in_epiyear(y)) weeks"))
    end
    return (y, w)
end
```

**What:** Delphi packs epiweeks as one number — `202620` means year 2026, week 20.
`divrem(202620, 100)` splits it into `(2026, 20)` in one step.

**Why it validates:** a garbled decode is far more likely than a real week 54. Failing loudly
beats producing dates in the wrong year.

**`x isa Integer ? ... : ...`** accepts either a number or its string form, because CSV and
JSON disagree about which one they send.

### `parse_epiday(x)`

```julia
function parse_epiday(x)
    s = strip(string(x))
    length(s) == 8 || throw(ValidationError(...))
    return Date(s, dateformat"yyyymmdd")
end
```

**What:** the daily equivalent. `20200601` → June 1st, 2020. The length check catches
truncated values before the date parser produces something misleading.

### `period_bounds(time_type, time_value)`

```julia
function period_bounds(time_type::AbstractString, time_value)
    tt = lowercase(strip(time_type))
    if tt == "day"
        d = parse_epiday(time_value); return (d, d)
    elseif tt == "week"
        y, w = parse_epiweek(time_value)
        return (epiweek_start(y, w), epiweek_end(y, w))
    else
        throw(ValidationError(...))
    end
end
```

**What:** the payoff function. Takes either encoding and returns a time span.

Daily → `(d, d)`, a one-day span. Weekly → the full Sunday–Saturday span.

**Why this matters:** this is the *single place* in the package that knows there are two
time encodings. Everything downstream sees spans. That's what the two-date-field design in
`EpiObservation` buys you.

### `parse_issue(time_type, issue)`

```julia
function parse_issue(time_type::AbstractString, issue)
    (issue === missing || issue === nothing) && return missing
    issue isa AbstractString && isempty(strip(issue)) && return missing
    ...
    return epiweek_end(y, w)   # for weekly
end
```

**What:** converts the publication date, handling absence.

**The subtlety:** `issue` uses the *same* encoding as the signal. A weekly signal's issue is
an epiweek, not a calendar date. And a week is a span, so it resolves to the week's **end**
— publication can't precede the period being reported, so the closing Saturday is the
tightest defensible bound.

Three ways of saying "no issue" (`missing`, `nothing`, `""`) all collapse to `missing`.

---

## `src/geo.jl` — place identifiers

### `GEO_TYPE_MAP`

```julia
const GEO_TYPE_MAP = Dict{String,GeoLevel}(
    "nation" => NATION, "hhs" => HHS_REGION, "state" => STATE, ..., "hsa_nci" => HSA_NCI,
)
```

**What:** a lookup table from Delphi's text labels to our enum. Some have two spellings
(`"hhs"` and `"hhs_region"`) because the API isn't perfectly consistent.

`hsa_nci` is there because it shows up in the live API catalogue even though it's barely
documented. Leaving it out would make real queries crash.

### `parse_geo_level(s)`

```julia
function parse_geo_level(s::AbstractString)
    key = lowercase(strip(s))
    lvl = get(GEO_TYPE_MAP, key, nothing)
    lvl === nothing && throw(ValidationError("unrecognised geo_type ..."))
    return lvl
end

parse_geo_level(l::GeoLevel) = l
```

**What:** text → enum, case-insensitively.

**Why it throws instead of defaulting:** a wrong geo level mislabels *every row* in the
response. Better to fail on an unknown type than to quietly claim county data is state data.
The message lists the valid options.

**The second method** takes an already-parsed `GeoLevel` and returns it unchanged. That's
multiple dispatch used for convenience — callers don't have to care whether they already
converted.

### `normalize_geo_id(level, raw)`

```julia
function normalize_geo_id(level::GeoLevel, raw)
    s = strip(string(raw))
    isempty(s) && throw(ValidationError(...))
    if level == COUNTY
        return all(isdigit, s) ? lpad(s, 5, '0') : lowercase(s)
    else
        return lowercase(s)
    end
end
```

**What:** cleans up a place identifier.

**The real hazard:** county FIPS codes are five digits and some start with zero. `"06075"`
is San Francisco. If anything reads that column as a number, it becomes `6075` — which
still *looks* like a plausible code. You've silently relabelled your data with a different
place, and nothing warns you.

`lpad(s, 5, '0')` pads back to five digits. Only for counties, because an HHS region really
is a small number like `9`, and padding it to `"00009"` would be wrong.

---

## `src/transport.jl` — the network boundary

Everything above this file works with an `EpiResponse` and never touches HTTP.

### `RateLimitInfo`

```julia
struct RateLimitInfo
    limit::Union{Int,Nothing}
    remaining::Union{Int,Nothing}
    reset::Union{DateTime,Nothing}
    retry_after::Union{Int,Nothing}
end
```

**What:** what the server said about your remaining quota.

Delphi sometimes sends headers like `x-my-remaining: 55` telling you how many requests you
have left. **Sometimes** — their servers are load-balanced and only some machines send them.
So every field is optional and all-`nothing` is normal, not an error.

**Why capture it at all:** a future rate limiter can be far smarter using real server state
than by guessing. It's free to record now.

### `EpiResponse`

```julia
struct EpiResponse
    status::Int
    body::Vector{UInt8}
    headers::Dict{String,String}
    request::String
end
```

**What:** a response, stripped of any HTTP-library specifics — status code, raw bytes,
headers, and a scrubbed description of what was asked.

**Why not just use HTTP.jl's own type:** because then the mock transport would have to
fabricate one, and every layer above would be tied to that library. This is the seam that
makes offline testing possible.

**`Vector{UInt8}`** is raw bytes, not text — the body might not be valid text at all.

### `body_string(r)` and `_parse_int(s)`

```julia
body_string(r::EpiResponse) = String(copy(r.body))
_parse_int(s) = s === nothing ? nothing : tryparse(Int, strip(s))
```

Two one-liners. `body_string` turns bytes into text (`copy` because Julia's `String`
constructor otherwise empties the original array — a real gotcha). `_parse_int` parses a
number that might be absent; `tryparse` returns `nothing` on failure instead of throwing.

The `_` prefix marks it internal.

### `ratelimit(r)`

```julia
function ratelimit(r::EpiResponse)
    reset_raw = _parse_int(get(r.headers, "x-my-reset", nothing))
    RateLimitInfo(..., reset_raw === nothing ? nothing : unix2datetime(reset_raw), ...)
end
```

**What:** pulls those quota headers out, if present. `get(dict, key, nothing)` returns the
default rather than erroring on a missing key. `unix2datetime` converts a Unix timestamp
into a real date.

### `canonical_query(params)`

```julia
function canonical_query(params)
    pairs = sort!([(string(k), string(v)) for (k, v) in params]; by = first)
    join(("$(HTTP.escapeuri(k))=$(HTTP.escapeuri(v))" for (k, v) in pairs), "&")
end
```

**What:** turns `Dict("b"=>2, "a"=>1)` into `"a=1&b=2"` — always in that order.

**Why sorting matters more than tidiness:** `MockTransport` looks up test fixtures *by this
string*. Julia's `Dict` doesn't guarantee iteration order, so without sorting the same
logical request could miss its fixture depending on internal hashing. That's a maddening
intermittent test failure.

**`escapeuri`** encodes characters that aren't URL-safe — `*` becomes `%2A`.

### `request_key(endpoint, params)`

```julia
request_key(endpoint, params) = string(endpoint, "?", canonical_query(params))
```

**What:** the full identity of a request — `"covidcast/?a=1&b=2"`. Used as a fixture key and
in error messages. Contains no credentials, by construction.

### `AbstractTransport` and `DELPHI_BASE_URL`

```julia
abstract type AbstractTransport end
const DELPHI_BASE_URL = "https://api.delphi.cmu.edu/epidata/"
```

The category that both transports belong to, and the API's address in one place so it's
changeable without hunting through the code.

### `HTTPTransport`

```julia
struct HTTPTransport <: AbstractTransport
    base_url::String
    api_key::Union{String,Nothing}
    max_retries::Int
    base_delay::Float64
    max_delay::Float64
    timeout::Int
end

function HTTPTransport(; base_url = DELPHI_BASE_URL,
                         api_key = get(ENV, "DELPHI_EPIDATA_KEY", nothing),
                         max_retries = 3, base_delay = 1.0, max_delay = 30.0, timeout = 60)
```

**What:** the real network client, plus a keyword constructor with sensible defaults so
`HTTPTransport()` just works.

**`get(ENV, "DELPHI_EPIDATA_KEY", nothing)`** reads an environment variable, defaulting to
none. Keys live in the environment, never in code.

### `auth_headers(t)`

```julia
function auth_headers(t::HTTPTransport)
    t.api_key === nothing && return Pair{String,String}[]
    token = base64encode(string("epidata:", t.api_key))
    return ["Authorization" => string("Basic ", token)]
end
```

**What:** builds the authentication header — HTTP Basic auth, which is the string
`username:password` base64-encoded.

**Why a header and not a URL parameter:** URLs end up in server access logs, browser
history, `Referer` headers sent to third parties, and exception messages. Headers mostly
don't. There's a test asserting the key never appears in a query string.

**Note:** base64 is *encoding*, not encryption — anyone can decode it. The protection is
HTTPS, which encrypts headers in transit. Base64 is just the format Basic auth specifies.

### `_headers_dict(h)`

```julia
_headers_dict(h) = Dict{String,String}(lowercase(string(k)) => string(v) for (k, v) in h)
```

Normalises header names to lowercase. HTTP header names are case-insensitive, and servers
are inconsistent (`Retry-After` vs `retry-after`), so lowercasing once means lookups
elsewhere can't miss.

### `backoff_delay(t, attempt, retry_after)`

```julia
function backoff_delay(t::HTTPTransport, attempt::Integer, retry_after::Union{Int,Nothing})
    retry_after !== nothing && return Float64(min(retry_after, t.max_delay))
    base = min(t.base_delay * 2.0^(attempt - 1), t.max_delay)
    return base * (0.5 + rand())
end
```

**What:** how long to wait before retrying.

**Rule 1 — obey the server.** If it sent `Retry-After`, use that. It knows when its own
window resets; guessing shorter just earns another rejection. Still capped by `max_delay`
so a hostile value can't hang you for an hour.

**Rule 2 — otherwise back off exponentially.** `2.0^(attempt-1)` gives 1s, 2s, 4s, 8s.

**Rule 3 — add jitter.** `* (0.5 + rand())` scatters each delay randomly between 50% and
150% of the target. If ten workers were throttled at the same instant, without jitter they'd
all wake up simultaneously and collide again — a "thundering herd." Randomness spreads them.

### `is_retryable(status)`

```julia
is_retryable(status::Integer) = status == 429 || status >= 500
```

**What:** should we try again? Yes for 429 ("slow down") and 5xx ("server broke"). No for
4xx.

**Why not 4xx:** those mean *your request* was wrong. It will be exactly as wrong next time,
and each retry burns one of your 60 hourly requests.

### `fetch_raw(t::HTTPTransport, endpoint, params)`

The real network call:

```julia
for attempt in 1:(t.max_retries + 1)
    resp = try
        r = HTTP.get(url; query = params, headers = headers,
                     readtimeout = t.timeout, status_exception = false, retry = false)
        EpiResponse(r.status, Vector{UInt8}(r.body), _headers_dict(r.headers), key)
    catch e
        e isa InterruptException && rethrow()
        attempt > t.max_retries && throw(TransportError(key, 0, sprint(showerror, e)))
        sleep(backoff_delay(t, attempt, nothing)); continue
    end
    last_resp = resp
    (is_retryable(resp.status) && attempt <= t.max_retries) || return resp
    sleep(backoff_delay(t, attempt, ratelimit(resp).retry_after))
end
```

**Two important flags:**

- `status_exception = false` — don't throw on a 404. We want to *inspect* error responses,
  because Delphi puts meaningful information in their bodies.
- `retry = false` — turn off HTTP.jl's own retrying. We do it ourselves so the policy is
  explicit and testable.

**The `try`/`catch` handles a different failure class:** a connection that never got a
status at all — DNS failure, TLS failure, timeout. Those retry like a 5xx.

**`e isa InterruptException && rethrow()`** — if the user pressed Ctrl-C, don't swallow it.

**`status = 0`** in the resulting `TransportError` means "never got a response."

### `MockTransport`

```julia
struct MockTransport <: AbstractTransport
    fixtures::Dict{String,EpiResponse}
    calls::Vector{String}
end
```

**What:** a fake transport. Instead of a network call, it looks up a pre-recorded response
in a dictionary. It also records every request into `calls`.

**Why `calls` matters:** tests can assert not just *what came back* but *what was sent* —
including that the API key never appeared in the query string.

```julia
resp === nothing && throw(ValidationError("no fixture for ..."))
```

**Why an unknown key throws** rather than returning empty: a test that quietly got "no data"
because of a typo in its own fixture key would pass for entirely the wrong reason. The error
lists available keys so the typo is obvious.

**This type is the reason the test suite exists.** Testing "what happens on a 400" against a
real server would mean somehow making it fail on demand. Here it's one line.

### `mock_response(body; status, headers, request)`

A small helper for building an `EpiResponse` in tests without going through HTTP.jl.

---

## `src/standardize.jl` — messy input, clean table

### `coerce_float` — five methods

```julia
coerce_float(::Missing) = missing
coerce_float(::Nothing) = missing
coerce_float(x::Real) = isnan(x) ? missing : Float64(x)
function coerce_float(s::AbstractString) ... end
coerce_float(::Any) = missing
```

**What:** turn whatever arrived into either a number or `missing`.

This is multiple dispatch at its most practical: one name, five bodies, Julia picks by type.

- Already absent → `missing`
- A number → keep it, **unless it's `NaN`**
- A string → parse it; `""`, `"NA"`, `"NaN"`, `"null"`, `"none"` and unparseable garbage
  all become `missing`
- Anything else → `missing`

**`::Missing` with no name** means "I need this type for dispatch but won't use the value."

**Why `NaN` becomes `missing`:** Delphi uses `NaN` as the placeholder next to a non-zero
missing code. Left as a float, `NaN` silently poisons every calculation it touches —
`NaN + 5` is `NaN`, and no one is told. As `missing`, Julia forces you to handle it.

**Why a catch-all instead of an error:** one weird cell shouldn't fail an entire download of
50,000 rows. The missing code preserves *why*.

### `coerce_missing_code` — five methods

```julia
coerce_missing_code(::Missing) = NOT_MISSING
function coerce_missing_code(x::Integer)
    lo, hi = Int(typemin(MissingCode)), Int(typemax(MissingCode))
    return (lo <= x <= hi) ? MissingCode(Int8(x)) : OTHER
end
coerce_missing_code(::Any) = OTHER
```

**What:** integer code → enum.

**Absent means `NOT_MISSING`** — the value is fine. That's the common case, and some sources
omit the column entirely.

**Unknown codes become `OTHER`, not an error.** If Delphi adds code `6` next year, rows
should still import. `typemin`/`typemax` find the valid range automatically, so this doesn't
need updating when the enum grows.

### `_colnames(raw, rows)` and `_get(row, name, avail)`

```julia
function _colnames(raw, rows)
    sch = Tables.schema(raw)
    sch === nothing || return Set{Symbol}(sch.names)
    st = iterate(rows); st === nothing && return Set{Symbol}()
    return Set{Symbol}(Tables.columnnames(st[1]))
end

@inline function _get(row, name::Symbol, avail::Set{Symbol})
    name in avail || return missing
    v = Tables.getcolumn(row, name)
    return v === nothing ? missing : v
end
```

**The problem:** JSON payloads often *omit* a field rather than sending it as null. Asking
for a field that isn't there throws.

**The fix:** work out which columns exist **once**, up front, then check membership per
lookup. The naive alternative — a `try`/`catch` around every field of every row — would be
enormously slower.

`Tables.schema` asks a table what columns it has; some sources can't say, so there's a
fallback that peeks at the first row. `@inline` asks the compiler to paste this in directly
since it's called eleven times per row.

### `standardize(::DelphiCovidcast, raw)`

The heart of the transform:

```julia
function standardize(::DelphiCovidcast, raw)
    rows = Tables.rows(raw)
    avail = _colnames(raw, rows)
    n = Base.IteratorSize(typeof(rows)) isa Base.HasLength ? length(rows) : 0

    source = Vector{Symbol}(); sizehint!(source, n)
    ...
    for row in rows
        tt = string(_get(row, :time_type, avail))
        lvl = parse_geo_level(string(_get(row, :geo_type, avail)))
        ps, pe = period_bounds(tt, _get(row, :time_value, avail))
        push!(source, ...); push!(value, coerce_float(...)); ...
    end
    return StructArray{EpiObservation}((; source, signal, ...))
end
```

**What:** loop over rows, clean each field, append to per-column vectors, wrap in a
`StructArray`.

**`::DelphiCovidcast` with no variable name** — the tag is only there to select this method.

**Why build columns directly** rather than making `EpiObservation`s and converting: a
`StructArray` *is* these vectors. Building rows first would mean a million temporary objects
and a transpose.

**`sizehint!`** pre-allocates so vectors don't repeatedly resize while filling. `n` is the
row count when the source knows it, `0` when it doesn't — just an optimisation either way.

**`(; source, signal, ...)`** is shorthand for `(source = source, signal = signal, ...)`.

### `EpiTable(obs)` and `empty_table()`

```julia
EpiTable(obs::AbstractVector{EpiObservation}) = StructArray(obs)
empty_table() = StructArray{EpiObservation}((source = Symbol[], ...))
```

Two conveniences: build a table from loose observations (useful in tests), and build a
zero-row table with correct column types, for code that needs a valid empty result rather
than an exception. `Symbol[]` is an empty vector of `Symbol`.

---

## `src/sources/delphi.jl` — speaking Delphi

### `COVIDCAST_ENDPOINT` and `COVIDCAST_CSV_HEADER`

```julia
const COVIDCAST_ENDPOINT = "covidcast/"
const COVIDCAST_CSV_HEADER = "geo_value,signal,source,geo_type,time_type,time_value," *
                             "direction,issue,lag,missing_value,missing_stderr," *
                             "missing_sample_size,value,stderr,sample_size"
```

The URL path, and the exact header line the endpoint emits — captured from a real response,
not from documentation. `*` concatenates strings in Julia.

**Why store the header:** it's how we recognise a valid CSV response. A body that's neither
JSON nor this exact header gets rejected rather than fed to a parser to fail obscurely.

### `csv_header(src)` and `endpoint(src)`

```julia
csv_header(::DelphiCovidcast) = COVIDCAST_CSV_HEADER
endpoint(::DelphiCovidcast) = COVIDCAST_ENDPOINT
```

Dispatch again. When `fluview` arrives it gets its own methods, and `decode_response` needs
no changes at all.

### `check_result(request, code, message)`

```julia
function check_result(request, code, message)
    code == 1 && return nothing
    code == -2 && throw(NoResultsError(request))
    code == 2 && throw(TruncatedResultsError(request, message))
    throw(EpidataError(request, code, message))
end
```

**What:** Delphi's status codes → our exceptions.

| Code | Meaning |
|---|---|
| `1` | success |
| `-1` | error |
| `-2` | no results |
| `2` | **truncated** — you hit the row cap |

**Why `2` is the important one.** It arrives looking exactly like success. Treat it as
success and you silently analyse a fragment of your data with no indication anything is
wrong — worse than an error, because an error at least tells you. It gets its own type so a
future chunked-fetch layer can catch it and subdivide the query.

### `try_json_envelope(body)`

```julia
function try_json_envelope(body::AbstractString)
    startswith(lstrip(body), '{') || return nothing
    obj = try JSON3.read(body) catch; return nothing end
    obj isa JSON3.Object || return nothing
    haskey(obj, :result) || return nothing
    ...
    return (code, msg, data)
end
```

**What:** "is this Delphi's JSON error format? If so, pull out the pieces."

**Why it returns `nothing` instead of throwing:** it's called on bodies that are usually CSV
and occasionally an HTML error page. Not-JSON is an *expected* outcome here, not an
exception. Each check bails early and cheaply.

### `decode_response(src, resp)`

The most important function in the package.

**The background:** the standard advice about this API is *"Delphi returns errors with HTTP
200, so ignore the status code and trust the `result` field."* That is only true in JSON
mode. This package requests CSV, where the measured reality is:

| Case | Status | Body |
|---|---|---|
| success | 200 | 15-column CSV |
| **no results** | **200** | **completely empty — zero bytes, no `result` field at all** |
| invalid parameter | **400** | JSON `{"result": -1, ...}` — JSON despite asking for CSV |
| unknown endpoint | 404 | HTML |

So in CSV mode, **emptiness itself is the no-results signal**, and validation errors *do*
use a proper 400. Following the common advice gives you a client that mishandles both.

The function follows that table in order:

```julia
if isempty(stripped)                          # 1. empty body
    resp.status == 200 && throw(NoResultsError(resp.request))
    throw(TransportError(resp.request, resp.status, ""))
end

env = try_json_envelope(stripped)             # 2. Delphi's own error format
if env !== nothing
    code, msg, data = env
    check_result(resp.request, code, msg)
    return data === nothing ? throw(NoResultsError(...)) : data
end

if !(200 <= resp.status < 300)                # 3. not JSON, not success
    throw(TransportError(resp.request, resp.status, stripped))
end

if !startswith(stripped, expected)            # 4. wrong shape entirely
    throw(EpidataError(...))
end

return CSV.File(resp.body;                    # 5. actual data
                types = Dict("geo_value" => String), stringtype = String)
```

**Why JSON is checked before the status code:** the server's own message ("missing
parameter: need one of [signal, signals]") is far more useful than a bare "HTTP 400."

**`types = Dict("geo_value" => String)`** forces that one column to stay text. Without it,
CSV parsing reads `"06075"` as the number `6075` and the leading zero is gone before
`normalize_geo_id` ever sees it. Fixing it at the parse boundary is the only reliable place.

**Everything funnels through here**, so there's exactly one place errors can leak from — and
every branch has a recorded fixture.

### `format_time_values(time_type, tv)`

```julia
function format_time_values(time_type::AbstractString, tv)
    fmt1(d::Date) = tt == "week" ? ... : Dates.format(d, dateformat"yyyymmdd")
    tv isa AbstractString && return String(strip(tv))
    tv isa Integer && return string(tv)
    tv isa Date && return fmt1(tv)
    if tv isa AbstractRange && eltype(tv) <: Date
        return string(fmt1(first(tv)), "-", fmt1(last(tv)))
    end
    ...
end
```

**What:** accepts whatever a user naturally reaches for and produces Delphi's packed wire
format.

`"202620-202629"`, `202620`, `Date(2026,5,17)`, a range of dates, or a list of any of those.
Dates are converted according to `time_type`, so you can query weekly signals with real
dates instead of computing epiweeks by hand.

**`fmt1` is a nested function** — defined inside, so it can see `tt` without being passed it.

### `covidcast_params(; ...)`

```julia
function covidcast_params(; data_source, signal, time_type, geo_type, time_values,
                            geo_value = "*", as_of = nothing, issues = nothing, lag = nothing)
    tt = lowercase(strip(time_type))
    tt in ("day", "week") || throw(ValidationError(...))
    parse_geo_level(geo_type)
    params = Dict{String,String}(..., "format" => "csv")
    as_of === nothing || (params["as_of"] = format_time_values(tt, as_of))
    ...
end
```

**What:** builds the query dictionary and checks it locally first.

**Keyword arguments with no default are required** — omit one and you get a clear error.
`geo_value = "*"` means all places.

**Why validate locally:** the anonymous limit is 60 requests/hour. Spending one to be told
you typed `"weekly"` is a real cost, and these two checks are free. `parse_geo_level` is
called purely for its throw-on-bad-input side effect.

**`as_of`, `issues`, `lag`** are the revision controls — "what did the data look like as of
this date." Only added when supplied.

### `fetch_signal(; ...)`

```julia
function fetch_signal(; transport = HTTPTransport(), as_of = nothing,
                        issues = nothing, lag = nothing, kwargs...)
    src = DelphiCovidcast()
    params = covidcast_params(; as_of, issues, lag, kwargs...)
    resp = fetch_raw(transport, endpoint(src), params)
    return standardize(src, decode_response(src, resp))
end
```

**What:** the one function most users ever call. Four lines: build the query, fetch, decode,
standardise.

**`kwargs...`** collects any other keyword arguments and forwards them, so this doesn't have
to re-list every parameter.

**`transport = HTTPTransport()`** as a default means normal use is simple, while tests can
pass a `MockTransport` and never touch the network.

---

## `src/store.jl` — onto disk and back

### `DICT_ENCODED_COLUMNS`

```julia
const DICT_ENCODED_COLUMNS = (:source, :signal, :geo_id, :geo_level, :missing_code)
```

**What:** which columns get dictionary encoding.

**Dictionary encoding, explained:** if a column is `["ca","ca","ny","ca","ny"]`, store the
distinct values once (`["ca","ny"]`) and then just indices (`[0,0,1,0,1]`). Massive win when
values repeat.

**Why only these five:** they repeat constantly — one source, one signal, a few thousand geo
ids across hundreds of thousands of rows. `value` is a different float every time, where a
dictionary is *pure overhead* — you store every value once **plus** an index for it.

Arrow.jl offers `dictencode = true`, which applies it to everything including the floats.
Measured on 500k rows: no encoding 14.7 MiB, blanket 12.7 MiB, **selective 9.5 MiB**.
Choosing the right columns beats the blanket flag by 25%.

### `save(tbl, path; compress = nothing)`

```julia
function save(tbl, path::AbstractString; compress::Union{Symbol,Nothing} = nothing)
    cols = Tables.columntable(tbl)
    encoded = NamedTuple{keys(cols)}(
        ntuple(i -> keys(cols)[i] in DICT_ENCODED_COLUMNS ?
                    Arrow.DictEncode(cols[i]) : cols[i], length(cols)))
    Arrow.write(path, encoded; compress)
    return path
end
```

**What:** writes the table to an Arrow file, wrapping selected columns in `Arrow.DictEncode`
and leaving the rest alone. `ntuple` builds the new set of columns; `NamedTuple{keys(cols)}`
puts the names back.

**Returns the path**, so you can nest calls: `load(save(tbl, p))`.

**Why compression defaults to off.** This looks backwards until you see the measurements.
Compression and zero-copy reading are mutually exclusive — a compressed file *must* be
decompressed into fresh memory when opened, which defeats memory-mapping entirely:

| | size | open + scan | allocations |
|---|---|---|---|
| Arrow + zstd | 9.5 MiB | 30.8 ms | 20.3 MiB |
| Arrow uncompressed | 20.3 MiB | **0.835 ms** | **0.04 MiB** |

37× faster and 463× fewer allocations, for 11 MiB more disk. A cache exists to be read
repeatedly, so it should be the fast one. `compress = :zstd` is there for archives.

**"Zero-copy" / "memory-mapped"** means the OS maps the file into memory and reads pages only
as touched — no parsing step at all. That's the entire reason to use Arrow.

### `load(path)`

```julia
function load(path::AbstractString)
    t = Arrow.Table(path)
    return StructArray{EpiObservation}((
        source = _materialize(Symbol, t.source),
        geo_level = GeoLevel.(t.geo_level),
        ...
    ))
end
```

**What:** reads the file back into an `EpiTable`.

**`GeoLevel.(t.geo_level)`** — that dot is broadcasting: apply `GeoLevel` to every element.

**Why this conversion is needed at all:** because `arrowtypes.jl` deliberately skipped the
extension-name registration to keep the file portable, Arrow doesn't know to convert these
back and returns raw `Int8`. This is where we pay that price. There's a test asserting these
come back as enums, because if this line were ever dropped the table would still look
plausible while comparing unequal to what was saved.

### `_materialize(T, col)`

```julia
_materialize(::Type{T}, col) where {T} = T[convert(T, x) for x in col]
_materialize(::Type{Union{T,Missing}}, col) where {T} =
    Union{T,Missing}[x === missing ? missing : convert(T, x) for x in col]
```

**What:** converts Arrow's lazy column types into plain Julia vectors.

**Why:** Arrow hands back its own specialised array types and string views. Converting means
the returned `EpiTable` is an ordinary table whose element type is exactly
`EpiObservation` — which is what makes `load(save(x)) == x` actually true.

**`where {T}`** makes it generic over any type. The second method handles `Union{T,Missing}`
separately because you can't `convert` a `missing` into a `Float64`.

---

## `test/` — how it is checked

### One suite, and it never touches the network

**1329 tests, all offline and deterministic.** Requests are served either by
`MockTransport` reading recorded fixtures, or — for the real HTTP path — by a throwaway
server on localhost.

There used to be a second, live suite gated behind an environment variable. It was
removed, and the reasoning is worth keeping:

- **Most of it was redundant.** It re-tested epiweek spans, the Arrow round-trip, and the
  empty-body error, all of which the offline suite already covers deterministically.
- **Parts were fragile.** It asserted `issorted(...)` on row order, which Delphi never
  promised, and asserted a hardcoded week window would keep returning data forever.
- **A failing live test is a category error.** A test asserts *your code* is correct. A
  live check asserts *someone else's server* hasn't changed. Those have different failure
  meanings and belong in different places.
- **It didn't do its stated job.** It claimed to catch fixture drift — but only if someone
  ran it, and nothing made anyone run it. Opt-in checks rot.
- **On failure, you want re-recording, not a red X.** A script that refreshes fixtures is
  strictly more useful than one that complains they're stale.

That check now lives in `scripts/check_upstream.jl`.

### `test/fixtures/`

Real response bodies captured from the live API, not hand-written approximations.

| File | What it captures |
|---|---|
| `covidcast_success.csv` | a normal two-row response |
| `covidcast_noresults.csv` | **a genuinely empty file** — CSV mode's no-results signal |
| `covidcast_validation_error.json` | 400 + JSON, despite `format=csv` |
| `covidcast_noresults.json` | JSON mode's `result: -2`, for contrast |
| `covidcast_truncated.json` | `result: 2` — **synthetic**, couldn't be triggered on demand |

The zero-byte file has a note in the fixtures README telling future-you not to "fix" it by
adding a header row. The emptiness *is* the behaviour under test.

### What each test file covers

| File | Focus |
|---|---|
| `test_epiweek.jl` | 813 tests — anchors, every day 2010–2035, the 53-week years, a guard against the ISO shortcut |
| `test_geo.jl` | the FIPS leading zero, unknown geo types throwing |
| `test_transport.jl` | query canonicalisation, key never in the URL, backoff bounds, jitter range |
| `test_http_transport.jl` | the **real** HTTP path, against a localhost server |
| `test_decode.jl` | every branch of the error table, against recorded fixtures |
| `test_standardize.jl` | column types, spans, coercion of every messy input form |
| `test_store.jl` | Arrow round-trip, enum fidelity, DataFrames interop |

**Why `test_http_transport.jl` exists separately.** `fetch_raw` has two methods — one for
`HTTPTransport`, one for `MockTransport` — and they share no code. Every other test goes
through the mock, so for a long time the real one had *zero* coverage. That wasn't
theoretical: an HTTP.jl keyword deprecation sat unnoticed in it for exactly that reason.

The fix is a throwaway `HTTP.serve!` server on an ephemeral localhost port, returning
scripted responses. Still fully offline, but it exercises query building, auth headers,
retry behaviour, and response construction for real. It covers things the mock can't:
that a 5xx is actually retried to success, that a 4xx is actually *not* retried, that
header names come back lowercased, and that a dead port becomes a `TransportError`.

**Why so much on epiweeks:** date arithmetic is where silent wrongness hides. An off-by-one
in week numbering shifts your entire time series by seven days and nothing crashes.

### `test/portability_check/`

A small Go program that reads an Arrow file from *outside* Julia and checks the enum columns
carry no Julia-specific metadata.

**Why Go specifically:** `arrow-go` is an independent native implementation of the format,
not a binding to the same C++ library that Python's `pyarrow` wraps. So Go agreeing with
Julia is real cross-implementation evidence; two wrappers around shared code agreeing would
prove much less.

It earned its keep immediately — it caught a claim in the README that was wrong.

```bash
go -C test/portability_check run . "$PWD/out.arrow"
```

The absolute path is required: `go -C` runs the tool from its own module directory, so
relative paths resolve from there instead of where you typed the command. The tool detects
this and says so, because the failure is otherwise baffling.

---

## `bench/` — the numbers

`bench/size_and_reload.jl` exists so the README's figures are **reproducible rather than
asserted**. Separate `Project.toml` so benchmark dependencies don't burden anyone installing
the package.

- **`synthetic_table(n)`** — generates 500,000 fake observations with realistic cardinality:
  a few sources and signals, 3,000 geo ids, high-entropy floats. The entropy matters —
  dictionary encoding looks far better than it is on data where values repeat, so faking
  that would flatter the result dishonestly. `Xoshiro(seed)` makes it reproducible.
- **`write_json`** — writes the same data as JSON, the shape a raw API dump arrives in.
- **`mib(path)`** — file size in MiB.
- **`scan_arrow` / `scan_json`** — open the file and sum a column. The minimum real work a
  consumer does, so the comparison is about the format rather than an artificial read.
- **`main()`** — writes every variant, prints sizes, benchmarks the reads.

It also measures the two *rejected* strategies (no dictionary encoding, blanket encoding)
alongside the chosen one, so the design decision is visible rather than just its outcome.

**`@benchmark`** runs code many times and reports the distribution. The minimum is used
rather than the mean because it's the least contaminated by unrelated system noise.

---

## Questions you might get asked

**"Why not just use a DataFrame everywhere?"**
DataFrames is a heavyweight dependency. A modelling package that only wants to read an
Arrow file shouldn't pay its load time. `StructArray` satisfies the same Tables.jl
interface, and `DataFrame(tbl)` converts in one call — with a test proving it.

**"Why is `missing_code` only about `value`?"**
Delphi sends three codes (`value`, `stderr`, `sample_size`). The schema keeps the one for
`value` because that's the measurement. The other two are recoverable from the fields being
`missing`, just without the reason. A deliberate simplification, documented in `types.jl`.

**"Why is there so much error handling for one endpoint?"**
Because the error behaviour is genuinely counterintuitive and undocumented, and the
consequences are silent. `result: 2` in particular returns partial data that looks complete.

**"Isn't the dispatch overkill with one source?"**
With only `covidcast`, honestly yes. `fluview` is what justifies it — and not just for
different column names. One fluview row carries *several* measures (`wili`, `ili`,
`num_ili`, `num_patients`), so it fans out into several `EpiObservation`s. Different
cardinality, not just different names.

**"What's not done yet?"**
A rate limiter, concurrent chunked fetching, catalogue-based validation, `fluview`, and an
incremental on-disk cache. The rate limiter matters soonest — 60 requests/hour means an
unthrottled loop breaks almost immediately.
