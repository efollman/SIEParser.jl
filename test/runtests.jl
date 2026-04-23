using Test
using SomatSIE
using SomatSIE: SieFile, Spigot, Stream, Tag, Tags, Output, libsie_version,
                spigot, channels, tests, tags, dimensions, dimension,
                channel, test, findchannel, findtest, containingtest,
                next!, numrows, numdims, numblocks, block, coltype,
                getfloat64, isstring, isbinary, value, key, valuesize,
                id, testid, name, index, nchannels, ntests, reset!,
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

    @testset "library info" begin
        v = libsie_version()
        @test v isa AbstractString
        @test !isempty(v)
    end

    @testset "open/close" begin
        @test isfile(FILE_MIN)
        f = SieFile(FILE_MIN)
        @test isopen(f)
        @test nchannels(f) >= 1
        @test ntests(f)    >= 1
        close(f)
        @test !isopen(f)
        # idempotent
        close(f)
    end

    @testset "do-block open" begin
        result = open(SieFile, FILE_MIN) do f
            (nchannels(f), ntests(f))
        end
        @test result[1] >= 1
        @test result[2] >= 1
    end

    @testset "missing file -> SieError" begin
        @test_throws SomatSIE.SieError SieFile(joinpath(DATA, "does_not_exist.sie"))
    end

    @testset "tests / channels / dims" begin
        open(SieFile, FILE_MIN) do f
            ts = tests(f)
            @test !isempty(ts)
            for t in ts
                @test id(t) isa Integer
                @test name(t) isa AbstractString
                for c in channels(t)
                    @test c isa SomatSIE.Channel
                    @test id(c) isa Integer
                    @test testid(c) == id(t)
                    @test numdims(c) >= 1
                    for d in dimensions(c)
                        @test index(d) isa Integer
                    end
                    # round-trip lookup
                    @test findchannel(f, id(c)) !== nothing
                    @test containingtest(f, c) !== nothing
                    @test id(containingtest(f, c)) == id(t)
                end
                @test findtest(f, id(t)) !== nothing
            end
        end
    end

    @testset "tags (file/test/channel/dimension)" begin
        open(SieFile, FILE_MIN) do f
            ftags = tags(f)
            @test length(ftags) >= 0
            for tag in ftags
                @test key(tag) isa AbstractString
                @test isstring(tag) || isbinary(tag)
                if isstring(tag)
                    @test value(tag) isa AbstractString
                else
                    @test value(tag) isa Vector{UInt8}
                end
                @test valuesize(tag) == ncodeunits_or_size(value(tag))
            end

            for t in tests(f)
                ttags = tags(t)
                @test get(ttags, "definitely-not-a-tag-key", nothing) === nothing
                @test !haskey(ttags, "definitely-not-a-tag-key")
                for c in channels(t)
                    ct = tags(c)
                    @test length(ct) >= 0
                    for d in dimensions(c)
                        dt = tags(d)
                        @test length(dt) >= 0
                    end
                end
            end
        end
    end

    @testset "spigot iteration & read(file, dim)" begin
        open(SieFile, FILE_MIN) do f
            ch = first(channels(f))
            # Iterate the spigot directly
            spigot(f, ch) do s
                @test numblocks(s) >= 0
                total = 0
                for out in s
                    @test out isa Output
                    @test numrows(out) >= 0
                    @test numdims(out) == numdims(ch)
                    total += numrows(out)
                end
            end
            # Materialize each dimension separately
            for dim in dimensions(ch)
                v = read(f, dim)
                @test v isa AbstractVector
                # Float64 column → Vector{Float64}; raw → Vector{Vector{UInt8}}
                @test eltype(v) === Float64 || eltype(v) === Vector{UInt8}
                @test length(v) >= 0
            end
        end
    end

    @testset "spigot reset / position" begin
        open(SieFile, FILE_MIN) do f
            ch = first(channels(f))
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
            open(SieFile, FILE_VBM) do f
                @test nchannels(f) > 1
                # Read a handful of channels' first dimension and assert it works
                for c in first(channels(f), min(3, nchannels(f)))
                    v = read(f, first(dimensions(c)))
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
