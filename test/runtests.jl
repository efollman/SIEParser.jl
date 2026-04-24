using Test
using SomatSIE
using SomatSIE: SieFile, Spigot, Stream, Tags, Output,
                opensie, findchannel,
                spigot,
                next!, numrows, numdims, numblocks, block, coltype,
                getfloat64,
                reset!,
                add!, numgroups

# Helpers
ncodeunits_or_size(v::AbstractString) = ncodeunits(v)
ncodeunits_or_size(v::AbstractVector{UInt8}) = length(v)

const DATA = joinpath(@__DIR__, "data")

# Pick small, well-known files from the test corpus.
const FILE_MIN   = joinpath(DATA, "sie_min_timhis_a_19EFAA61.sie")
const FILE_VBM   = joinpath(DATA, "sie_comprehensive_VBM_DE81A7BA.sie")
const FILE_FLOAT = joinpath(DATA, "sie_float_conversions_20050908.sie")

@testset "SomatSIE.jl" begin

    @testset "open/close" begin
        @test isfile(FILE_MIN)
        f = SieFile(FILE_MIN)
        @test isopen(f)
        @test length(f.tests) >= 1
        close(f)
        @test !isopen(f)
        # idempotent
        close(f)
    end

    @testset "do-block open" begin
        result = opensie(FILE_MIN) do f
            length(f.tests)
        end
        @test result >= 1
    end

    @testset "missing file -> SieError" begin
        @test_throws SomatSIE.SieError SieFile(joinpath(DATA, "does_not_exist.sie"))
    end

    @testset "tests / channels / dims" begin
        opensie(FILE_MIN) do f
            ts = f.tests
            @test !isempty(ts)
            for t in ts
                @test t.id isa Integer
                @test t.id >= 1
                @test t.name isa AbstractString
                for c in t.channels
                    @test c isa SomatSIE.Channel
                    @test c.id isa Integer
                    @test c.id >= 1
                    @test length(c.dims) >= 1
                    for d in c.dims
                        @test d.id isa Integer
                        @test d.id >= 1
                    end
                    # round-trip lookup
                    @test findchannel(t, c.name) !== nothing
                end
            end
        end
    end

    @testset "dot-property accessors" begin
        opensie(FILE_MIN) do f
            t = first(f.tests)
            @test t.id isa Integer
            @test t.name isa AbstractString
            @test t.channels isa Vector
            @test t.tags isa Tags
            c = first(t.channels)
            @test c.id isa Integer
            @test c.name isa AbstractString
            @test c.dims isa Vector
            @test c.tags isa Tags
            d = first(c.dims)
            @test d.id isa Integer
            @test d.name isa AbstractString
            @test d.tags isa Tags
            # propertynames advertises the dot-public surface
            @test :tests in propertynames(f)
            @test :id    in propertynames(t)
            @test :dims  in propertynames(c)
            # SieFile has no `channels` property — must go through tests
            @test_throws ErrorException f.channels
        end
    end

    @testset "tags (file/test/channel/dimension)" begin
        opensie(FILE_MIN) do f
            ftags = f.tags
            @test ftags isa Tags
            @test ftags isa AbstractDict
            @test length(ftags) >= 0
            for (k, v) in ftags
                @test k isa AbstractString
                @test v isa AbstractString || v isa Vector{UInt8}
            end

            for t in f.tests
                ttags = t.tags
                @test get(ttags, "definitely-not-a-tag-key", nothing) === nothing
                @test !haskey(ttags, "definitely-not-a-tag-key")
                for c in t.channels
                    ct = c.tags
                    @test length(ct) >= 0
                    for d in c.dims
                        dt = d.tags
                        @test length(dt) >= 0
                    end
                end
            end
        end
    end

    @testset "spigot iteration & collect(dim)" begin
        opensie(FILE_MIN) do f
            ch = first(first(f.tests).channels)
            # Iterate the spigot directly
            spigot(f, ch) do s
                @test numblocks(s) >= 0
                total = 0
                for out in s
                    @test out isa Output
                    @test numrows(out) >= 0
                    @test numdims(out) == length(ch.dims)
                    total += numrows(out)
                end
            end
            # Materialize each dimension separately
            for dim in ch.dims
                v = collect(dim)
                @test v isa AbstractVector
                # Float64 column → Vector{Float64}; raw → Vector{Vector{UInt8}}
                @test eltype(v) === Float64 || eltype(v) === Vector{UInt8}
                @test length(v) >= 0
            end
        end
    end

    @testset "Dimension as a vector (indexing / collect)" begin
        opensie(FILE_MIN) do f
            ch = first(first(f.tests).channels)
            for dim in ch.dims
                full = collect(dim)
                n    = length(full)
                @test length(dim) == n
                @test size(dim)   == (n,)
                @test eltype(dim) === eltype(full)
                # dim[:] equals collect(dim)
                @test dim[:]       == full
                if n > 0
                    @test dim[1]      == full[1]
                    @test dim[end]    == full[end]
                    @test firstindex(dim) == 1
                    @test lastindex(dim)  == n
                    mid = (n + 1) ÷ 2
                    @test dim[mid] == full[mid]
                    # range read
                    lo = mid
                    hi = min(n, mid + 3)
                    @test dim[lo:hi] == full[lo:hi]
                    # iteration matches collect
                    @test [x for x in dim] == full
                end
                # bounds
                @test_throws BoundsError dim[0]
                @test_throws BoundsError dim[n + 1]
            end
        end
    end

    @testset "spigot reset / position" begin
        opensie(FILE_MIN) do f
            ch = first(first(f.tests).channels)
            s = spigot(f, ch)
            try
                first_block = next!(s)
                if first_block !== nothing
                    @test numrows(first_block) >= 0
                    reset!(s)
                    @test position(s) >= 0
                    again = next!(s)
                    @test again !== nothing
                    @test block(again) == block(first_block)
                end
            finally
                close(s)
            end
        end
    end

    @testset "comprehensive VBM file" begin
        if isfile(FILE_VBM)
            opensie(FILE_VBM) do f
                allchans = [c for t in f.tests for c in t.channels]
                @test length(allchans) > 1
                # Read a handful of channels' first dimension and assert it works
                for c in first(allchans, min(3, length(allchans)))
                    v = collect(first(c.dims))
                    @test v isa AbstractVector
                    @test eltype(v) === Float64 || eltype(v) === Vector{UInt8}
                end
            end
        end
    end

    @testset "Stream incremental ingest" begin
        if isfile(FILE_MIN)
            bytes = read(FILE_MIN)
            s = Stream()
            try
                # Feed in two halves
                half = length(bytes) ÷ 2
                @test add!(s, view(bytes, 1:half)) >= 0
                @test add!(s, view(bytes, half+1:length(bytes))) >= 0
                @test numgroups(s) >= 0
            finally
                close(s)
            end
        end
    end

end
