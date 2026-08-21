using Arrow
using DataFrames
using Dates
using StructArrays
using Tables
using EpiDataKit: save, load, scan, provenance, decode_response, mock_response, standardize,
                  DICT_ENCODED_COLUMNS, empty_table

# A table exercising every column type that can go wrong on the way to disk: both enums,
# present and absent floats, a present and an absent issue date, and multiple geo ids so
# the dictionary-encoded columns actually have something to encode.
function sample_table()
    obs = [
        EpiObservation(:nssp, :pct_ed_visits_covid, STATE, "ca",
                       Date(2026, 5, 17), Date(2026, 5, 23),
                       0.07, missing, missing, Date(2026, 8, 1), 10, NOT_MISSING),
        EpiObservation(:nssp, :pct_ed_visits_covid, STATE, "ny",
                       Date(2026, 5, 17), Date(2026, 5, 23),
                       missing, 0.5, 100.0, Date(2026, 8, 1), 10, CENSORED),
        EpiObservation(:jhu_csse, :confirmed_incidence_num, COUNTY, "06075",
                       Date(2020, 6, 1), Date(2020, 6, 1),
                       2437.0, missing, missing, missing, missing, NOT_MISSING),
    ]
    return StructArray(obs)
end

@testset "store" begin
    tbl = sample_table()

    @testset "round-trip preserves everything" begin
        mktempdir() do dir
            p = save(tbl, joinpath(dir, "t.arrow"))
            back = load(p)

            @test back == tbl
            @test length(back) == length(tbl)
            for (a, b) in zip(back, tbl)
                @test isequal(a, b)
            end
        end
    end

    @testset "enum columns come back as enums" begin
        # Without an Arrow extension annotation these columns decode as raw Int8, so
        # `load` reconstructs them explicitly. If that step is ever dropped, the table
        # would still look plausible while comparing unequal, hence an explicit check.
        mktempdir() do dir
            back = load(save(tbl, joinpath(dir, "t.arrow")))
            @test back.geo_level isa Vector{GeoLevel}
            @test back.missing_code isa Vector{MissingCode}
            @test back.geo_level[1] == STATE
            @test back.geo_level[3] == COUNTY
            @test back.missing_code[2] == CENSORED
        end
    end

    @testset "missings and date intervals survive" begin
        mktempdir() do dir
            back = load(save(tbl, joinpath(dir, "t.arrow")))
            @test back.value[2] === missing
            @test back.stderr[1] === missing
            @test back.sample_size[2] === 100.0
            @test back.issue[3] === missing
            @test back.issue[1] == Date(2026, 8, 1)
            @test back.period_end[1] - back.period_start[1] == Day(6)
            @test back.period_start[3] == back.period_end[3]
        end
    end

    @testset "county FIPS keeps its leading zero through Arrow" begin
        mktempdir() do dir
            back = load(save(tbl, joinpath(dir, "t.arrow")))
            @test back.geo_id[3] == "06075"
        end
    end

    @testset "compression is opt-in" begin
        mktempdir() do dir
            plain = save(tbl, joinpath(dir, "plain.arrow"))
            zstd = save(tbl, joinpath(dir, "zstd.arrow"); compress = :zstd)
            # Both must read back identically; the difference is only on disk.
            @test load(plain) == tbl
            @test load(zstd) == tbl
        end
    end

    @testset "enum columns decode as plain integers" begin
        # The portability contract: a foreign reader must not need this package. Enums are
        # registered with ArrowTypes as Int8 and given no extension name, so they arrive as
        # ordinary integers. `test/portability_check/` verifies the other half of this from
        # outside Julia, where the absence of extension metadata is actually visible.
        mktempdir() do dir
            t = Arrow.Table(save(tbl, joinpath(dir, "t.arrow")))
            @test eltype(t.geo_level) <: Integer
            @test eltype(t.missing_code) <: Integer
            @test Int.(t.geo_level) == [Int8(STATE), Int8(STATE), Int8(COUNTY)]
            @test Int.(t.missing_code) == [Int8(NOT_MISSING), Int8(CENSORED), Int8(NOT_MISSING)]
        end
    end

    @testset "empty table round-trips" begin
        mktempdir() do dir
            back = load(save(empty_table(), joinpath(dir, "empty.arrow")))
            @test length(back) == 0
            @test back isa EpiTable
        end
    end

    @testset "save rejects anything that is not an EpiTable" begin
        # A CatalogTable is a StructArray too, so without the type bound this would write
        # a file `load` then refuses.
        mktempdir() do dir
            @test_throws MethodError save(CatalogTable(CatalogEntry[]),
                                           joinpath(dir, "cat.arrow"))
        end
    end

    @testset "load rejects files that are not ours, with a typed error" begin
        # Regression: these used to surface as a bare `KeyError: key :source not found`
        # or an `ArgumentError` from the enum constructor, neither an EpiDataKitError,
        # so a caller catching this package's errors would miss them entirely.
        mktempdir() do dir
            Arrow.write(joinpath(dir, "foreign.arrow"), (a = [1, 2], b = ["x", "y"]))
            @test_throws StoreError load(joinpath(dir, "foreign.arrow"))
            @test StoreError <: EpiDataKitError

            write(joinpath(dir, "junk.txt"), "not an arrow file at all")
            @test_throws StoreError load(joinpath(dir, "junk.txt"))

            @test_throws StoreError load(joinpath(dir, "does_not_exist.arrow"))

            # The message has to name what was missing, or it is no better than a KeyError.
            err = try; load(joinpath(dir, "foreign.arrow")); catch e; e; end
            @test occursin("source", err.msg)
            @test occursin("a, b", err.msg)
        end
    end

    @testset "an unknown enum value says to upgrade" begin
        # GeoLevel and MissingCode are documented as append-only, so a file written by a
        # newer build can legitimately carry a level this one has never seen. Refusing is
        # right (guessing would misattribute the row), but the reader has to be told that
        # upgrading is the fix.
        mktempdir() do dir
            cols = Tables.columntable(sample_table())
            p = joinpath(dir, "future.arrow")
            Arrow.write(p, merge(cols, (geo_level = Int8[9, 9, 9],)))

            err = try; load(p); catch e; e; end
            @test err isa StoreError
            @test occursin("9", err.msg)
            @test occursin("GeoLevel", err.msg)
            @test occursin("newer version", err.msg)

            p2 = joinpath(dir, "future2.arrow")
            Arrow.write(p2, merge(cols, (missing_code = Int8[0, 0, 99],)))
            err2 = try; load(p2); catch e; e; end
            @test err2 isa StoreError
            @test occursin("MissingCode", err2.msg)
            @test occursin("row 3", err2.msg)
        end
    end

    @testset "an enum column at an unexpected width is still diagnosed" begin
        # Nothing this package writes produces these, but a file assembled by another
        # Arrow writer can. They must not surface as InexactError or MethodError from
        # inside the conversion.
        mktempdir() do dir
            cols = Tables.columntable(sample_table())
            write_with(name, gl) = (p = joinpath(dir, name); Arrow.write(p, merge(cols, (geo_level = gl,))); p)

            @test_throws StoreError load(write_with("wide.arrow", Int32[9999, 0, 0]))
            @test_throws StoreError load(write_with("huge.arrow", Int64[10^10, 0, 0]))
            @test_throws StoreError load(write_with("float.arrow", Float64[3.0, 3.0, 4.0]))
            @test_throws StoreError load(write_with("null.arrow",
                Union{Int8,Missing}[missing, 3, 4]))

            # A wider integer column that is still in range is legitimate and must load.
            back = load(write_with("wide_ok.arrow", Int64[3, 3, 4]))
            @test back.geo_level == [STATE, STATE, COUNTY]
        end
    end

    @testset "every defined enum value still round-trips" begin
        # The guard above must not have narrowed what is actually accepted.
        mktempdir() do dir
            lvls = collect(instances(GeoLevel))
            codes = [MissingCode(mod(Int8(i), Int8(length(instances(MissingCode)))))
                     for i in eachindex(lvls)]
            obs = [EpiObservation(:s, :x, lvls[i], "ca", Date(2020, 1, 1), Date(2020, 1, 1),
                                  1.0, missing, missing, missing, missing, codes[i])
                   for i in eachindex(lvls)]
            t = StructArray(obs)
            @test load(save(t, joinpath(dir, "all.arrow"))) == t
        end
    end

    @testset "scan is load without the copy" begin
        mktempdir() do dir
            p = save(tbl, joinpath(dir, "t.arrow"))
            lazy = scan(p)

            @test lazy == load(p)
            @test lazy == tbl
            @test eltype(lazy) === EpiObservation
            @test lazy[1] isa EpiObservation
            @test lazy.geo_level[1] == STATE
            @test lazy.missing_code[2] == CENSORED
            @test lazy.geo_id[3] == "06075"
            @test lazy.value[2] === missing
            @test lazy.issue[3] === missing
            # Still a Tables.jl source, so DataFrames and friends work off it unchanged.
            @test Tables.istable(lazy)
            @test Set(Tables.columnnames(lazy)) == Set(fieldnames(EpiObservation))
        end
    end

    @testset "scan checks enum columns at open" begin
        # The lazy path converts on access, so without an eager check an unknown value
        # would surface as a bare ArgumentError from wherever the row was first touched.
        mktempdir() do dir
            cols = Tables.columntable(sample_table())
            p = joinpath(dir, "future.arrow")
            Arrow.write(p, merge(cols, (geo_level = Int8[9, 9, 9],)))

            err = try; scan(p); catch e; e; end
            @test err isa StoreError
            @test occursin("newer version", err.msg)

            @test_throws StoreError scan(joinpath(dir, "does_not_exist.arrow"))
            Arrow.write(joinpath(dir, "foreign.arrow"), (a = [1, 2],))
            @test_throws StoreError scan(joinpath(dir, "foreign.arrow"))
        end
    end

    @testset "provenance records who wrote the file and when" begin
        mktempdir() do dir
            p = save(tbl, joinpath(dir, "t.arrow"))
            pr = EpiDataKit.provenance(p)

            @test pr.schema == EpiDataKit.SCHEMA_VERSION
            @test pr.version == string(pkgversion(EpiDataKit))
            # Parses as a UTC timestamp, and is not in the future.
            ts = DateTime(pr.saved_at, dateformat"yyyy-mm-dd\THH:MM:SS\Z")
            @test ts <= now(UTC) + Second(5)
            @test ts > now(UTC) - Hour(1)

            # Metadata must not disturb the data or the portability contract.
            @test load(p) == tbl
            t = Arrow.Table(p)
            @test eltype(t.geo_level) <: Integer
        end
    end

    @testset "a file without provenance reads back missing" begin
        # Nothing has shipped yet, but a foreign Arrow file with our columns is legitimate.
        mktempdir() do dir
            p = joinpath(dir, "bare.arrow")
            Arrow.write(p, Tables.columntable(sample_table()))
            pr = EpiDataKit.provenance(p)
            @test pr.saved_at === missing
            @test pr.version === missing
            @test pr.schema === missing
        end
    end

    @testset "dictionary-encoded columns are the repeated ones" begin
        # Float measurement columns are deliberately excluded: a dictionary over
        # high-entropy floats costs more than it saves.
        @test :geo_id in DICT_ENCODED_COLUMNS
        @test :source in DICT_ENCODED_COLUMNS
        @test :signal in DICT_ENCODED_COLUMNS
        @test :value ∉ DICT_ENCODED_COLUMNS
        @test :stderr ∉ DICT_ENCODED_COLUMNS
        @test :period_start ∉ DICT_ENCODED_COLUMNS
    end
end

@testset "DataFrames interop" begin
    # DataFrames is deliberately not a dependency: downstream modeling packages that
    # only want to read an Arrow file should not pay for its load time. But the
    # conversion has to actually work, so it is verified rather than merely claimed.
    tbl = sample_table()
    df = DataFrame(tbl)

    @test nrow(df) == 3
    @test Set(names(df)) == Set(string.(fieldnames(EpiObservation)))
    @test df.geo_id == ["ca", "ny", "06075"]
    @test df.value[2] === missing
    @test df.geo_level isa Vector{GeoLevel}

    @testset "copycols controls sharing" begin
        # DataFrames copies by default; sharing is available but has to be asked for.
        @test df.geo_id == tbl.geo_id
        @test df.geo_id !== tbl.geo_id
        @test DataFrame(tbl; copycols = false).geo_id === tbl.geo_id
    end

    @testset "a Tables.jl source all round" begin
        @test Tables.istable(tbl)
        @test Tables.columnaccess(tbl)
        @test Set(Tables.columnnames(tbl)) == Set(fieldnames(EpiObservation))
    end
end
