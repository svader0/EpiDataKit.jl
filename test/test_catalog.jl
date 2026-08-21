using Dates
using Logging
using EpiDataKit: empty_catalog, DelphiCovidcastMeta, COVIDCAST_META_ENDPOINT,
                  COVIDCAST_META_CSV_HEADER, csv_header, endpoint, catalog_params,
                  catalog_entries, coerce_int, decode_response, mock_response,
                  fluview_catalog_entries, FLUVIEW_GEO_LEVELS, FLUVIEW_MEASURES, fluview_geo,
                  catalog, request_key

# The catalog answers "what can I fetch", so it is a different schema from EpiObservation
# and a different file from src/sources/. These tests pin both halves of it: the live
# covidcast_meta rows, and the static fluview rows that no metadata endpoint publishes.

# Build a MockTransport that will answer exactly the request `catalog` should make.
function mock_for_catalog(body; status = 200, kwargs...)
    params = catalog_params(; kwargs...)
    key = request_key(COVIDCAST_META_ENDPOINT, params)
    return MockTransport(Dict(key => mock_response(body; status = status, request = key)))
end

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

    @testset "a geo_type this version does not know drops one row, not the catalog" begin
        # Delphi added hsa_nci to this endpoint before GEO_TYPE_MAP had it. catalog is the
        # function you would call to discover a new level, so it cannot be the one that
        # throws on it.
        body = COVIDCAST_META_CSV_HEADER * "\n" *
            "nssp,pct_ed_visits_covid,week,state,202239,202632,51,0.0,6.14,1.1,0.95,1787169386,202633,1,203\n" *
            "nssp,pct_ed_visits_covid,week,orbital_ring,202239,202632,7,0.0,6.14,1.1,0.95,1787169386,202633,1,203\n"
        src = DelphiCovidcastMeta()

        cat = with_logger(NullLogger()) do
            catalog_entries(decode_response(src, mock_response(body)))
        end
        @test length(cat) == 1
        @test cat.geo_level == [STATE]

        # The drop is reported, so it cannot pass for data that was never there.
        @test_logs (:warn,) match_mode = :any catalog_entries(
            decode_response(src, mock_response(body)))
    end

    @testset "an all-unknown payload is an empty catalog, not an error" begin
        body = COVIDCAST_META_CSV_HEADER * "\n" *
            "nssp,pct_ed_visits_covid,week,orbital_ring,202239,202632,7,0.0,6.14,1.1,0.95,1787169386,202633,1,203\n"
        src = DelphiCovidcastMeta()

        cat = with_logger(NullLogger()) do
            catalog_entries(decode_response(src, mock_response(body)))
        end
        @test isempty(cat)
        # The vcat in `catalog` needs matching column types, so an empty result has to keep
        # them rather than collapse to Any.
        @test eltype(cat.first_period) == Union{Date,Missing}
    end

    @testset "end to end on a recorded response" begin
        t = mock_for_catalog(fixture("covidcast_meta_success.csv"))
        cat = catalog(; transport = t)

        @test cat isa CatalogTable
        # 13 covidcast rows from the fixture, plus the 44 static fluview rows.
        @test length(cat) == 57
        @test Set(cat.source) == Set([:chng, :nssp, :fluview])
        @test Set(cat.fetch_with) == Set([:fetch_covidcast, :fetch_fluview])
        @test length(t.calls) == 1
        @test startswith(only(t.calls), COVIDCAST_META_ENDPOINT)
        @test occursin("format=csv", only(t.calls))
        @test !occursin("api_key", only(t.calls))
    end

    @testset "a geo_type filter narrows the result, not the request" begin
        t = mock_for_catalog(fixture("covidcast_meta_success.csv"); geo_type = "nation")
        cat = catalog(; transport = t, geo_type = "nation")

        @test all(==(NATION), cat.geo_level)
        # 2 covidcast nation rows (chng, nssp) + 11 fluview measures at NATION.
        @test length(cat) == 13
        @test !occursin("geo_types", only(t.calls))

        # The alias has to select the same level. That it cannot go on the wire is the
        # whole reason this filter runs here.
        t2 = mock_for_catalog(fixture("covidcast_meta_success.csv"); geo_type = "hhs_region")
        @test Set(catalog(; transport = t2, geo_type = "hhs_region").geo_level) ==
              Set([HHS_REGION])
    end

    @testset "a time_type filter reaches the wire and the result" begin
        t = mock_for_catalog(fixture("covidcast_meta_success.csv"); time_type = "day")
        cat = catalog(; transport = t, time_type = "day")

        @test occursin("time_types=day", only(t.calls))
        @test all(==(:day), cat.time_type)
        # Every fluview signal is weekly, so a day filter removes that half entirely.
        @test :fluview ∉ cat.source
        @test length(cat) == 6
    end

    @testset "a signal without a source is filtered locally" begin
        t = mock_for_catalog(fixture("covidcast_meta_success.csv"); signal = "wili")
        cat = catalog(; transport = t, signal = "wili")

        @test !occursin("signals", only(t.calls))
        @test all(==(:wili), cat.signal)
        @test length(cat) == length(FLUVIEW_GEO_LEVELS)
    end

    @testset "asking only for fluview makes no request" begin
        # covidcast_meta has no `fluview` data_source, so the reply is certain to be empty.
        # Sending it would spend one of 60 per hour to learn nothing.
        t = MockTransport()
        cat = catalog(; transport = t, source = "fluview")

        @test isempty(t.calls)
        @test length(cat) == 44
        @test all(==(:fluview), cat.source)
    end

    @testset "an empty covidcast half does not hide the fluview half" begin
        # census_division exists in fluview and not in covidcast_meta, so upstream answers
        # with an empty body. Whether the query found nothing is decided after both halves.
        t = mock_for_catalog(fixture("covidcast_noresults.csv"); geo_type = "census_division")
        cat = catalog(; transport = t, geo_type = "census_division")

        @test length(cat) == length(FLUVIEW_MEASURES)
        @test all(==(CENSUS_DIVISION), cat.geo_level)
    end

    @testset "nothing anywhere is still an error" begin
        t = mock_for_catalog(fixture("covidcast_noresults.csv");
                             source = "nssp", signal = "no_such_signal")
        @test_throws NoResultsError catalog(; transport = t,
                                            source = "nssp", signal = "no_such_signal")
    end

    @testset "a misspelled filter costs no request" begin
        t = MockTransport()
        @test_throws ValidationError catalog(; transport = t, geo_type = "planet")
        @test_throws ValidationError catalog(; transport = t, time_type = "year")
        @test isempty(t.calls)
    end

    @testset "errors propagate from the decode layer" begin
        # Each is a distinct upstream failure mode, and each has to survive the trip out
        # through catalog rather than being swallowed by the empty-half handling.
        @test_throws EpidataError catalog(;
            transport = mock_for_catalog(fixture("covidcast_validation_error.json");
                                         status = 400))
        @test_throws TruncatedResultsError catalog(;
            transport = mock_for_catalog(fixture("covidcast_truncated.json")))
        @test_throws TransportError catalog(;
            transport = mock_for_catalog("<html>gateway</html>"; status = 502))
    end
end
