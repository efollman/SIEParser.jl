using Test

# Shared fixtures (data paths) used by both suites.
include("test_common.jl")

@testset "SomatSIE.jl" begin
    # Public, documented API surface (README, docstrings).
    include("test_public.jl")

    # Unexported helpers. Refactors of these are allowed to break this file.
    include("test_internal.jl")

    # Boundary / raw / binary-tag / LRU-stress coverage.
    include("test_edge_cases.jl")

    # Aqua + JET. Off by default; opt in with SOMATSIE_RUN_QUALITY=1.
    if get(ENV, "SOMATSIE_RUN_QUALITY", "0") == "1"
        include("test_quality.jl")
    end
end
