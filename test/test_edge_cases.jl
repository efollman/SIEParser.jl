# Edge-case coverage for the public API: empty/boundary ranges, raw
# (CAN) columns, binary tag values, and stressed LRU eviction. These
# cases were called out as gaps in the package audit.

using Test
using SomatSIE
using SomatSIE: SieFile, Tags, Channel, Dimension, opensie

const FILE_CAN = joinpath(DATA, "can_raw_test-v-1-5-0-129-build-1218.sie")

@testset "Edge cases" begin

    @testset "boundary ranges on a libsie dimension" begin
        opensie(FILE_MIN) do f
            ch = first(first(f.tests).channels)
            for dim in ch.dims
                n = length(dim)
                n == 0 && continue
                full = collect(dim)
                # Empty range — should produce a typed empty vector.
                empty_r = dim[n:n-1]
                @test isempty(empty_r)
                @test eltype(empty_r) === eltype(dim)
                # Single-element range == single-index read.
                @test dim[n:n] == [full[n]]
                @test dim[1:1] == [full[1]]
                # Full range == collect.
                @test dim[1:n] == full
                # Negative & large indices.
                @test_throws BoundsError dim[-1]
                @test_throws BoundsError dim[typemax(Int)]
            end
        end
    end

    @testset "raw (CAN) columns" begin
        if isfile(FILE_CAN)
            opensie(FILE_CAN) do f
                # Find at least one raw-typed dimension and confirm it
                # round-trips through `collect`.
                found_raw = false
                for t in f.tests, c in t.channels, d in c.dims
                    if eltype(d) === Vector{UInt8}
                        found_raw = true
                        v = collect(d)
                        @test v isa Vector{Vector{UInt8}}
                        if !isempty(v)
                            @test v[1] isa Vector{UInt8}
                            # Range read agrees with collect.
                            n = length(v)
                            @test d[1:min(n, 4)] == v[1:min(n, 4)]
                            # Single-element read agrees too.
                            @test d[1] == v[1]
                        end
                    end
                end
                @test found_raw
            end
        end
    end

    @testset "tag value union (String + Vector{UInt8})" begin
        opensie(FILE_MIN) do f
            # Walk every tag; the type union must hold uniformly.
            tag_iters = Any[f.tags]
            for t in f.tests
                push!(tag_iters, t.tags)
                for c in t.channels
                    push!(tag_iters, c.tags)
                    for d in c.dims
                        push!(tag_iters, d.tags)
                    end
                end
            end
            for ts in tag_iters
                @test ts isa Tags
                for (k, v) in ts
                    @test k isa String
                    @test v isa String || v isa Vector{UInt8}
                end
            end
        end
    end

    @testset "empty in-memory dimensions and channels" begin
        d_empty = Dimension(Float64[])
        @test isempty(d_empty)
        @test eltype(d_empty) === Float64
        @test collect(d_empty) == Float64[]
        @test d_empty[1:0] == Float64[]
        @test_throws BoundsError d_empty[1]

        ch_empty = Channel("e", SomatSIE.AbstractDimension[])
        @test length(ch_empty) == 0
    end

    @testset "sie_detach alias" begin
        d  = Dimension([1.0, 2.0]; id = 1)
        ch = Channel("c", [d])
        @test sie_detach === sieDetach
        @test sie_detach(d)  === d
        @test sie_detach(ch) === ch
    end

    @testset "LRU eviction does not corrupt cache" begin
        # Force LRU pressure by walking a channel that has more blocks
        # than the eviction threshold, then re-reading from the start.
        # On the bundled test files this typically just exercises the
        # cache happy-path; the assertion is "results stay consistent".
        opensie(FILE_MIN) do f
            ch = first(first(f.tests).channels)
            for dim in ch.dims
                n = length(dim)
                n == 0 && continue
                full = collect(dim)
                # Touch many small windows to exercise the LRU.
                step = max(1, n ÷ 32)
                for i in 1:step:n
                    j = min(i + 3, n)
                    @test dim[i:j] == full[i:j]
                end
                # Re-read end-to-end after stressing the LRU.
                @test collect(dim) == full
            end
        end
    end

end
