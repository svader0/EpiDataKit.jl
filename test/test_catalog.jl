using Dates
using Logging
using EpiDataKit: empty_catalog, DelphiCovidcastMeta, COVIDCAST_META_ENDPOINT,
                  COVIDCAST_META_CSV_HEADER, csv_header, endpoint, catalog_params,
                  catalog_entries, coerce_int, decode_response, mock_response,
                  fluview_catalog_entries, FLUVIEW_GEO_LEVELS, FLUVIEW_MEASURES, fluview_geo,
                  catalog, request_key
using EpiDataKit: v5_catalog_entries, V5_METADATA_ENDPOINT, V5_SOURCES

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
        @test eltype(cat.first_period) == Union{Date,Missing}
        @test eltype(cat.num_locations) == Union{Int,Missing}
    end

    @testset "an empty catalog keeps its column types" begin
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
        @test csv_header(src) == COVIDCAST_META_CSV_HEADER
        @test count(==(','), COVIDCAST_META_CSV_HEADER) == 14
    end

    @testset "only the filters the endpoint honors reach the wire" begin
        @test catalog_params() == Dict("format" => "csv")

        p = catalog_params(source = "nssp")
        @test p["signals"] == "nssp:*"

        p = catalog_params(source = "nssp", signal = "pct_ed_visits_covid")
        @test p["signals"] == "nssp:pct_ed_visits_covid"

        @test !haskey(catalog_params(signal = "wili"), "signals")

        @test catalog_params(time_type = "WEEK ")["time_types"] == "week"

        @test !haskey(catalog_params(geo_type = "hhs_region"), "geo_types")
        @test !haskey(catalog_params(geo_type = "state"), "geo_types")
        @test catalog_params(geo_type = STATE) == Dict("format" => "csv")
    end

    @testset "a misspelled filter is caught before a request is built" begin
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
        @test HSA_NCI in cat.geo_level
        @test length(unique(cat.geo_level)) == 7
    end

    @testset "packed times become the interval they denote" begin
        src = DelphiCovidcastMeta()
        cat = catalog_entries(decode_response(src,
            mock_response(fixture("covidcast_meta_success.csv"))))

        # The chng signal is retired, so a fixture refresh cannot move these dates.
        day = cat[findfirst(==(:day), cat.time_type)]
        @test day.first_period == Date(2020, 2, 1)     # min_time 20200201
        @test day.last_period == Date(2024, 2, 14)     # max_time 20240214
        @test day.last_issue == Date(2024, 2, 19)      # max_issue 20240219

        # nssp is live, so only min_time and the day-of-week structure survive a refresh.
        wk = cat[findfirst(==(:week), cat.time_type)]
        @test wk.first_period == Date(2022, 9, 25)     # 202239 opens Sun 2022-09-25
        @test wk.last_period > wk.first_period
        @test wk.last_issue >= wk.last_period
        @test dayofweek(wk.first_period) == 7          # Sunday
        @test dayofweek(wk.last_period) == 6           # Saturday
    end

    @testset "counts and lags come across as integers" begin
        src = DelphiCovidcastMeta()
        cat = catalog_entries(decode_response(src,
            mock_response(fixture("covidcast_meta_success.csv"))))

        nat = cat[findall(==(NATION), cat.geo_level)]
        @test all(==(1), nat.num_locations)
        # Counts move upstream, so the type and the sign are what hold.
        @test all(n -> n isa Int && n > 0, cat.num_locations)
        @test all(l -> l isa Int && l >= 0, cat.min_lag)
        @test all(l -> l isa Int && l >= 0, cat.max_lag)
    end

    @testset "coerce_int reads a whole number however it arrives" begin
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

        @test all(ismissing, cat.first_period)
        @test all(ismissing, cat.last_period)
        @test all(ismissing, cat.num_locations)
        @test all(ismissing, cat.last_issue)
        @test all(ismissing, cat.min_lag)
        @test all(ismissing, cat.max_lag)
    end

    @testset "every listed fluview level is one fetch_fluview accepts" begin
        for (region, lvl) in (("nat", NATION), ("hhs1", HHS_REGION),
                              ("cen1", CENSUS_DIVISION), ("ca", STATE))
            @test fluview_geo(region)[1] === lvl
            @test lvl in FLUVIEW_GEO_LEVELS
        end
        @test length(FLUVIEW_GEO_LEVELS) == 4
    end

    @testset "a geo_type this version does not know drops one row, not the catalog" begin
        body = COVIDCAST_META_CSV_HEADER * "\n" *
            "nssp,pct_ed_visits_covid,week,state,202239,202632,51,0.0,6.14,1.1,0.95,1787169386,202633,1,203\n" *
            "nssp,pct_ed_visits_covid,week,orbital_ring,202239,202632,7,0.0,6.14,1.1,0.95,1787169386,202633,1,203\n"
        src = DelphiCovidcastMeta()

        cat = with_logger(NullLogger()) do
            catalog_entries(decode_response(src, mock_response(body)))
        end
        @test length(cat) == 1
        @test cat.geo_level == [STATE]

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

        t2 = mock_for_catalog(fixture("covidcast_meta_success.csv"); geo_type = "hhs_region")
        @test Set(catalog(; transport = t2, geo_type = "hhs_region").geo_level) ==
              Set([HHS_REGION])
    end

    @testset "a time_type filter reaches the wire and the result" begin
        t = mock_for_catalog(fixture("covidcast_meta_success.csv"); time_type = "day")
        cat = catalog(; transport = t, time_type = "day")

        @test occursin("time_types=day", only(t.calls))
        @test all(==(:day), cat.time_type)
        @test :fluview ∉ cat.source                    # every fluview signal is weekly
        @test length(cat) == 6
    end

    @testset "a signal without a source is filtered locally" begin
        t = mock_for_catalog(fixture("covidcast_meta_success.csv"); signal = "wili")
        cat = catalog(; transport = t, signal = "wili")

        @test !occursin("signals", only(t.calls))
        @test all(==(:wili), cat.signal)
        @test length(cat) == length(FLUVIEW_GEO_LEVELS)
    end

    @testset "a wildcard signal behaves like no signal filter" begin
        t1 = mock_for_catalog(fixture("covidcast_meta_success.csv"); source = "nssp")
        plain = catalog(; transport = t1, source = "nssp")

        t2 = mock_for_catalog(fixture("covidcast_meta_success.csv"); source = "nssp")
        starred = catalog(; transport = t2, source = "nssp", signal = "*")

        @test only(t2.calls) == only(t1.calls)
        @test starred.signal == plain.signal
        @test starred.time_type == plain.time_type
        @test starred.geo_level == plain.geo_level
        @test starred.last_issue == plain.last_issue

        t3 = mock_for_catalog(fixture("covidcast_meta_success.csv"); source = "nssp")
        starred_sym = catalog(; transport = t3, source = "nssp", signal = :*)
        @test starred_sym.signal == plain.signal
    end

    @testset "asking only for fluview makes no request" begin
        t = MockTransport()
        cat = catalog(; transport = t, source = "fluview")

        @test isempty(t.calls)
        @test length(cat) == 44
        @test all(==(:fluview), cat.source)
    end

    @testset "a fluview-only query that matches nothing names no request" begin
        # fluview serves no county data, so this filter empties the static half.
        t = MockTransport()
        err = try
            catalog(; transport = t, source = "fluview", geo_type = "county")
            nothing
        catch e
            e
        end

        @test err isa NoResultsError
        @test isempty(t.calls)
        @test !occursin("covidcast_meta", err.request)
    end

    @testset "an empty covidcast half does not hide the fluview half" begin
        # census_division exists in fluview but not in covidcast_meta.
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
        @test_throws EpidataError catalog(;
            transport = mock_for_catalog(fixture("covidcast_validation_error.json");
                                         status = 400))
        @test_throws TruncatedResultsError catalog(;
            transport = mock_for_catalog(fixture("covidcast_truncated.json")))
        @test_throws TransportError catalog(;
            transport = mock_for_catalog("<html>gateway</html>"; status = 502))
    end

    @testset "V5 catalog" begin
        cat = v5_catalog_entries(fixture("v5_metadata.json"))

        @test cat isa CatalogTable
        @test !isempty(cat)
        @test :nssp in cat.source
        @test :pct_ed_visits_covid in cat.signal
        @test all(e -> e.fetch_with === :fetch_snapshot, cat)

        # metadata/ publishes no resolution, so this column is missing rather than guessed.
        @test all(e -> e.time_type === missing, cat)
        @test all(e -> e.num_locations === missing, cat)

        nssp = filter(e -> e.source === :nssp, cat)
        @test STATE in nssp.geo_level
        @test CENSUS_REGION in nssp.geo_level
        @test all(e -> e.first_period isa Date, nssp)
        @test all(e -> e.last_period >= e.first_period, nssp)
        @test all(e -> e.last_issue isa Date, nssp)

        # Only the sources this package can actually fetch belong in the catalog.
        @test all(s -> s in V5_SOURCES, unique(cat.source))
        @test :pophive ∉ cat.source
        @test :nwss ∉ cat.source
        # rvdss publishes null for every field; it must be skipped, not crash the parse.
        @test :rvdss ∉ cat.source

        @testset "catalog(api = :v5) makes one request" begin
            key = request_key(V5_METADATA_ENDPOINT, Dict{String,String}())
            t = MockTransport(Dict(key => mock_response(fixture("v5_metadata.json");
                                                        request = key)))
            c = catalog(api = :v5, transport = t)
            @test length(t.calls) == 1
            @test :nssp in c.source

            c2 = catalog(api = :v5, source = "nssp", geo_type = "state", transport = t)
            @test all(e -> e.source === :nssp && e.geo_level == STATE, c2)
            @test_throws NoResultsError catalog(api = :v5, source = "nssp",
                                                signal = "nope", transport = t)
            # V5 publishes no resolution, so a time_type filter can never match a V5 entry.
            @test_throws NoResultsError catalog(api = :v5, time_type = "week", transport = t)
        end

        @testset "an unknown api is rejected before any request" begin
            t9 = MockTransport()
            @test_throws ValidationError catalog(api = :v9, transport = t9)
            @test isempty(t9.calls)

            tboth = MockTransport()
            @test_throws ValidationError catalog(api = :both, transport = tboth)
            @test isempty(tboth.calls)
        end
    end
end
