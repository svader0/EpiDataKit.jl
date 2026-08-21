using Dates
using EpiDataKit: empty_catalog, DelphiCovidcastMeta, COVIDCAST_META_ENDPOINT,
                  COVIDCAST_META_CSV_HEADER, csv_header, endpoint

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
end
