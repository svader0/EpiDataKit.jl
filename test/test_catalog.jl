using Dates
using EpiDataKit: empty_catalog, DelphiCovidcastMeta, COVIDCAST_META_ENDPOINT,
                  COVIDCAST_META_CSV_HEADER, csv_header, endpoint, catalog_params,
                  catalog_entries, coerce_int, decode_response, mock_response,
                  fluview_catalog_entries, FLUVIEW_GEO_LEVELS, FLUVIEW_MEASURES, fluview_geo

# The catalog answers "what can I fetch", so it is a different schema from EpiObservation
# and a different file from src/sources/. These tests pin both halves of it: the live
# covidcast_meta rows, and the static fluview rows that no metadata endpoint publishes.

@testset "catalog" begin
    @testset "the schema is a table that indexes as rows" begin
        e = CatalogEntry(:nssp, :pct_ed_visits_covid, :week, STATE,
                         Date(2022, 9, 25), Date(2026, 8, 15), 51,
                         Date(2026, 8, 22), 1, 203, :fetch_covidcast)
        cat = CatalogTable([e])

        @test cat isa CatalogTable
        @test length(cat) == 1
        @test cat.source == [:nssp]
        @test cat.geo_level == [STATE]
        @test cat[1].signal === :pct_ed_visits_covid
        @test cat[1].last_issue == Date(2026, 8, 22)
        @test cat[1].num_locations == 51
        # Every extent column has to admit `missing`: fluview publishes none of them.
        @test eltype(cat.first_period) == Union{Date,Missing}
        @test eltype(cat.num_locations) == Union{Int,Missing}
    end

    @testset "an empty catalog keeps its column types" begin
        # vcat of the two halves needs matching column types, and an empty StructArray
        # built from an empty Vector does not reliably keep them.
        cat = empty_catalog()
        @test cat isa CatalogTable
        @test isempty(cat)
        @test eltype(cat.last_issue) == Union{Date,Missing}
        @test eltype(cat.geo_level) == GeoLevel
    end

    @testset "the meta endpoint is tagged like any other source" begin
        src = DelphiCovidcastMeta()
        @test src isa AbstractSource
        @test endpoint(src) == "covidcast_meta/"
        # decode_response gates a 200 body on this header matching exactly, so the
        # constant is a contract with the server, not a convenience.
        @test csv_header(src) == COVIDCAST_META_CSV_HEADER
        @test count(==(','), COVIDCAST_META_CSV_HEADER) == 14
    end

    @testset "only the filters the endpoint honors reach the wire" begin
        @test catalog_params() == Dict("format" => "csv")

        p = catalog_params(source = "nssp")
        @test p["signals"] == "nssp:*"

        p = catalog_params(source = "nssp", signal = "pct_ed_visits_covid")
        @test p["signals"] == "nssp:pct_ed_visits_covid"

        # A signal without its source cannot be written as a `source:signal` pair, so it
        # narrows nothing upstream and is applied to the result instead.
        @test !haskey(catalog_params(signal = "wili"), "signals")

        @test catalog_params(time_type = "WEEK ")["time_types"] == "week"

        # geo_type is validated but never sent. GEO_TYPE_MAP accepts "hhs_region" as an
        # alias for "hhs", and this endpoint answers an alias it does not know with an
        # empty body rather than an error, so sending it would look like "no data".
        @test !haskey(catalog_params(geo_type = "hhs_region"), "geo_types")
        @test !haskey(catalog_params(geo_type = "state"), "geo_types")
        # A GeoLevel is accepted directly, via parse_geo_level's passthrough method.
        @test catalog_params(geo_type = STATE) == Dict("format" => "csv")
    end

    @testset "a misspelled filter is caught before a request is built" begin
        # This endpoint returns 200 with an empty body for a parameter it does not
        # understand, so without a local check a typo is indistinguishable from no data.
        @test_throws ValidationError catalog_params(time_type = "year")
        @test_throws ValidationError catalog_params(geo_type = "planet")
    end

    @testset "meta rows become catalog entries" begin
        src = DelphiCovidcastMeta()
        raw = decode_response(src, mock_response(fixture("covidcast_meta_success.csv")))
        cat = catalog_entries(raw)

        @test cat isa CatalogTable
        @test length(cat) == 13
        @test Set(cat.source) == Set([:chng, :nssp])
        @test Set(cat.time_type) == Set([:day, :week])
        @test all(==(:fetch_covidcast), cat.fetch_with)
        # hsa_nci reached the API before it reached this package, so it is the level most
        # worth pinning.
        @test HSA_NCI in cat.geo_level
        @test length(unique(cat.geo_level)) == 7
    end

    @testset "packed times become the interval they denote" begin
        src = DelphiCovidcastMeta()
        cat = catalog_entries(decode_response(src,
            mock_response(fixture("covidcast_meta_success.csv"))))

        # A daily row's extent is the day itself, on both ends.
        day = cat[findfirst(==(:day), cat.time_type)]
        @test day.first_period == Date(2020, 2, 1)     # min_time 20200201
        @test day.last_period == Date(2024, 2, 14)     # max_time 20240214
        @test day.last_issue == Date(2024, 2, 19)      # max_issue 20240219

        # A weekly row's extent opens on the Sunday of min_time's MMWR week and closes on
        # the Saturday of max_time's, so the two ends read different halves of
        # period_bounds. Taking both from the same half would be six days out.
        wk = cat[findfirst(==(:week), cat.time_type)]
        @test wk.first_period == Date(2022, 9, 25)     # 202239 opens Sun 2022-09-25
        @test wk.last_period == Date(2026, 8, 15)      # 202632 closes Sat 2026-08-15
        @test wk.last_issue == Date(2026, 8, 22)       # 202633 closes Sat 2026-08-22
        @test dayofweek(wk.first_period) == 7          # Sunday
        @test dayofweek(wk.last_period) == 6           # Saturday
    end

    @testset "counts and lags come across as integers" begin
        src = DelphiCovidcastMeta()
        cat = catalog_entries(decode_response(src,
            mock_response(fixture("covidcast_meta_success.csv"))))

        nat = cat[findall(==(NATION), cat.geo_level)]
        @test all(==(1), nat.num_locations)
        @test 2426 in cat.num_locations                # nssp at county level
        @test all(l -> l isa Int && l >= 0, cat.min_lag)
        @test all(l -> l isa Int && l >= 0, cat.max_lag)
    end

    @testset "coerce_int reads a whole number however it arrives" begin
        # Renamed from coerce_lag, because the catalog reads num_locations with it too.
        @test coerce_int(51) == 51
        @test coerce_int("51") == 51
        @test coerce_int(51.0) == 51
        @test coerce_int(missing) === missing
        @test coerce_int("") === missing
    end

    @testset "fluview contributes a row per measure and level" begin
        cat = fluview_catalog_entries()

        @test cat isa CatalogTable
        @test length(cat) == length(FLUVIEW_MEASURES) * length(FLUVIEW_GEO_LEVELS)
        @test length(cat) == 44
        @test all(==(:fluview), cat.source)
        @test all(==(:fetch_fluview), cat.fetch_with)
        @test all(==(:week), cat.time_type)
        @test Set(cat.signal) == Set(FLUVIEW_MEASURES)
        @test Set(cat.geo_level) == Set(FLUVIEW_GEO_LEVELS)

        # The API publishes no per-signal coverage for fluview, and inventing one would be
        # worse than admitting it.
        @test all(ismissing, cat.first_period)
        @test all(ismissing, cat.last_period)
        @test all(ismissing, cat.num_locations)
        @test all(ismissing, cat.last_issue)
        @test all(ismissing, cat.min_lag)
        @test all(ismissing, cat.max_lag)
    end

    @testset "every listed fluview level is one fetch_fluview accepts" begin
        # These two lists live in different files and can drift apart. A level the catalog
        # advertises but fluview_geo rejects is a broken promise.
        for (region, lvl) in (("nat", NATION), ("hhs1", HHS_REGION),
                              ("cen1", CENSUS_DIVISION), ("ca", STATE))
            @test fluview_geo(region)[1] === lvl
            @test lvl in FLUVIEW_GEO_LEVELS
        end
        @test length(FLUVIEW_GEO_LEVELS) == 4
    end
end
