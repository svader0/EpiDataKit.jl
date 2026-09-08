using EpiDataKit
using Test

const FIXTURES = joinpath(@__DIR__, "fixtures")
fixture(name) = read(joinpath(FIXTURES, name), String)

@testset "EpiDataKit.jl" begin
    include("test_epiweek.jl")
    include("test_geo.jl")
    include("test_transport.jl")
    include("test_http_transport.jl")
    include("test_decode.jl")
    include("test_v5_decode.jl")
    include("test_v5_standardize.jl")
    include("test_v5_params.jl")
    include("test_standardize.jl")
    include("test_fetch_covidcast.jl")
    include("test_fetch_fluview.jl")
    include("test_store.jl")
    include("test_catalog.jl")
end