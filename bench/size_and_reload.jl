# Bench mark to read how big the cache is, and how cheap it
# is to read back.
#
# Run with:
#     julia --project=bench bench/size_and_reload.jl
#

using Arrow
using BenchmarkTools
using Dates
using EpiDataKit
using JSON3
using Printf
using Random
using StructArrays
using Tables

const N = 500_000           # number of  observations to generate for the benchmark
const rand_seed = 20260802  # seed for reproducible synthetic data

"""
Creates a bunch of synthetic date with realistic-ish cardinality. 
Aims for high-entropy measurements so that dictionary encoding is not artificially effective.
"""
function synthetic_table(n::Int = N; seed::Int = rand_seed)
    rng = Xoshiro(seed)
    sources = [:nssp, :nhsn, :jhu_csse, :fb_survey]
    signals = [:pct_ed_visits_covid, :pct_ed_visits_flu, :confirmed_admissions_covid_ew,
               :confirmed_admissions_flu_ew, :smoothed_cli]
    geos = [lpad(string(i), 5, '0') for i in 1:3000]
    week0 = Date(2020, 1, 5)

    starts = Vector{Date}(undef, n)
    ends = Vector{Date}(undef, n)
    @inbounds for i in 1:n
        s = week0 + Day(7 * rand(rng, 0:300))
        starts[i] = s
        ends[i] = s + Day(6)
    end

    value = Vector{Union{Float64,Missing}}(undef, n)
    stderr = Vector{Union{Float64,Missing}}(undef, n)
    sample = Vector{Union{Float64,Missing}}(undef, n)
    issue = Vector{Union{Date,Missing}}(undef, n)
    lag = Vector{Union{Int,Missing}}(undef, n)
    mcode = Vector{MissingCode}(undef, n)
    @inbounds for i in 1:n
        miss = rand(rng) < 0.05
        value[i] = miss ? missing : round(rand(rng) * 100; digits = 6)
        stderr[i] = rand(rng) < 0.5 ? missing : round(rand(rng); digits = 6)
        sample[i] = rand(rng) < 0.5 ? missing : round(rand(rng) * 5000; digits = 2)
        weeks = rand(rng, 1:12)
        issue[i] = rand(rng) < 0.02 ? missing : ends[i] + Day(7 * weeks)
        lag[i] = issue[i] === missing ? missing : weeks
        mcode[i] = miss ? CENSORED : NOT_MISSING
    end

    return StructArray{EpiObservation}((
        source = rand(rng, sources, n),
        signal = rand(rng, signals, n),
        geo_level = fill(COUNTY, n),
        geo_id = rand(rng, geos, n),
        period_start = starts,
        period_end = ends,
        value = value,
        stderr = stderr,
        sample_size = sample,
        issue = issue,
        lag = lag,
        missing_code = mcode,
    ))
end

"""Write the table as a JSON array of row objects for comparison, which we will need to read back in."""
function write_json(tbl, path)
    open(path, "w") do io
        JSON3.write(io, [(
            source = string(o.source), signal = string(o.signal),
            geo_level = Int(o.geo_level), geo_id = o.geo_id,
            period_start = string(o.period_start), period_end = string(o.period_end),
            value = o.value, stderr = o.stderr, sample_size = o.sample_size,
            issue = o.issue === missing ? nothing : string(o.issue),
            lag = o.lag,
            missing_code = Int(o.missing_code),
        ) for o in tbl])
    end
    return path
end

# Measure file size in MiB
mib(path) = filesize(path) / 1024^2

"""Open the file and do some arbitrary work on it."""
scan_arrow(path) = sum(skipmissing(Arrow.Table(path).value))
scan_load(path) = sum(skipmissing(EpiDataKit.load(path).value))
scan_scan(path) = sum(skipmissing(EpiDataKit.scan(path).value))

function scan_json(path)
    rows = JSON3.read(read(path, String))
    total = 0.0
    for r in rows
        v = r.value
        v === nothing || (total += v)
    end
    return total
end

function main()
    tbl = synthetic_table()
    @printf("rows: %d\n\n", length(tbl))

    dir = mktempdir()
    p_json = write_json(tbl, joinpath(dir, "obs.json"))
    p_plain = EpiDataKit.save(tbl, joinpath(dir, "plain.arrow"))
    p_zstd = EpiDataKit.save(tbl, joinpath(dir, "zstd.arrow"); compress = :zstd)

    # The two rejected write strategies, for comparison against store.jl's choice.
    cols = Tables.columntable(tbl)
    p_zstd_only = joinpath(dir, "zstd_only.arrow")
    Arrow.write(p_zstd_only, cols; compress = :zstd)
    p_zstd_global = joinpath(dir, "zstd_global.arrow")
    Arrow.write(p_zstd_global, cols; compress = :zstd, dictencode = true)

    printstyled("── file size ─────────────────────────────────────────────\n", bold=true, color=:blue)
    @printf("  %-38s %8.2f MiB\n", "JSON", mib(p_json))
    @printf("  %-38s %8.2f MiB  (%.1fx smaller)\n", "Arrow, uncompressed + selective dict",
            mib(p_plain), mib(p_json) / mib(p_plain))
    @printf("  %-38s %8.2f MiB  (%.1fx smaller)\n", "Arrow, zstd + selective dict",
            mib(p_zstd), mib(p_json) / mib(p_zstd))
    println()
    println("  write-option comparison (all zstd):")
    @printf("    %-36s %8.2f MiB\n", "no dict encoding", mib(p_zstd_only))
    @printf("    %-36s %8.2f MiB\n", "dictencode = true (every column)", mib(p_zstd_global))
    @printf("    %-36s %8.2f MiB  <- store.jl\n", "selective DictEncode", mib(p_zstd))
    println()

    printstyled("── open + scan one column ────────────────────────────────\n", bold=true, color=:blue)
    b_json = @benchmark scan_json($p_json) samples=3 evals=1 seconds=60
    b_zstd = @benchmark scan_arrow($p_zstd) samples=20 evals=1 seconds=60
    b_plain = @benchmark scan_arrow($p_plain) samples=20 evals=1 seconds=60
    b_load = @benchmark scan_load($p_plain) samples=20 evals=1 seconds=60
    b_scan = @benchmark scan_scan($p_plain) samples=20 evals=1 seconds=60

    for (name, b) in (("JSON", b_json), ("Arrow, zstd", b_zstd),
                      ("Arrow, uncompressed", b_plain),
                      ("EpiDataKit.scan", b_scan),
                      ("EpiDataKit.load", b_load))
        @printf("  %-22s %9.3f ms   %9.2f MiB allocated\n",
                name, minimum(b).time / 1e6, minimum(b).memory / 1024^2)
    end
    println()
    @printf("  uncompressed is %.0fx faster to scan than zstd, and allocates %.0fx less\n",
            minimum(b_zstd).time / minimum(b_plain).time,
            minimum(b_zstd).memory / max(minimum(b_plain).memory, 1))
    @printf("  load() costs %.0fx the time and %.0fx the memory of scan(), in\n",
            minimum(b_load).time / minimum(b_scan).time,
            minimum(b_load).memory / max(minimum(b_scan).memory, 1))
    println("  exchange for plain mutable vectors; scan() is read-only and mmap-backed")

    rm(dir; recursive = true)
end

main()
