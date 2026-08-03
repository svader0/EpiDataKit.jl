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
    include("test_standardize.jl")
    include("test_fetch_signal.jl")
    include("test_store.jl")
end

# This suite never touches the network. Checking that Delphi still behaves the way
# test/fixtures/ records is a separate concern with a different failure meaning — a red
# test here should mean our code is wrong, not that someone else's server moved. That
# check lives in scripts/check_upstream.jl and is run deliberately.
