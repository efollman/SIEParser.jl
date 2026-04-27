# Shared fixtures for the public- and internal-API test files. Loaded
# from `runtests.jl` before either testset file is included.

const DATA = joinpath(@__DIR__, "data")

# Pick small, well-known files from the test corpus.
const FILE_MIN   = joinpath(DATA, "sie_min_timhis_a_19EFAA61.sie")
const FILE_VBM   = joinpath(DATA, "sie_comprehensive_VBM_DE81A7BA.sie")
const FILE_FLOAT = joinpath(DATA, "sie_float_conversions_20050908.sie")
