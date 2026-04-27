# Public-API tests for SomatSIE.jl.
#
# Only exercises the documented surface from the README: `opensie`,
# `findchannel`, `sieDetach`, the unexported types (`SieFile`, `Test`,
# `Channel`, `Dimension`, `Tags`, `SieError`, `Vector*`), the dot
# accessors (`f.tests`, `t.channels`, `ch.dims`, `ch.name`, `ch.schema`,
# `ch.sr`, `x.tags`, `x.id`), `Dimension`'s `AbstractVector` interface
# (`length`, `size`, `eltype`, `dim[i]`, `dim[a:b]`, `dim[:]`,
# `collect(dim)`, iteration, bounds), the in-memory constructors, and
# the post-`close(f)` safety guard.
#
# Internal helpers (`spigot`, `Spigot`, `Output`, `next!`, `numrows`,
# `numdims`, `numblocks`, `block`, `coltype`, `getfloat64`, `reset!`,
# `LibSie*`) are NOT used here \u2014 see `test_internal.jl`.

using Test
using SomatSIE
using SomatSIE: SieFile, Tags,
                Channel, Dimension,
                opensie, findchannel

@testset "Public API" begin

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
            @test t.channels isa Vector
            @test t.tags isa Tags
            c = first(t.channels)
            @test c.id isa Integer
            @test c.name isa AbstractString
            @test c.dims isa Vector
            @test c.tags isa Tags
            d = first(c.dims)
            @test d.id isa Integer
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

    @testset "collect(dim) eltype contract" begin
        opensie(FILE_MIN) do f
            ch = first(first(f.tests).channels)
            for dim in ch.dims
                v = collect(dim)
                @test v isa AbstractVector
                # Float64 column → Vector{Float64}; raw → Vector{Vector{UInt8}}
                @test eltype(v) === Float64 || eltype(v) === Vector{UInt8}
                @test length(v) >= 0
            end
        end
    end

    @testset "length(::Channel)" begin
        # LibSieChannel: matches its dimensions' length.
        opensie(FILE_MIN) do f
            ch = first(first(f.tests).channels)
            @test length(ch) == length(first(ch.dims))
        end
        # VectorChannel: length of dim 1, 0 when empty.
        vc = Channel("c", [Dimension([1.0, 2.0, 3.0])])
        @test length(vc) == 3
        empty_vc = Channel("e", SomatSIE.AbstractDimension[])
        @test length(empty_vc) == 0
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

    @testset "In-memory Channel / Dimension construction" begin
        # Build a VectorDimension via the public Dimension(...) constructor.
        d1 = Dimension([1.0, 2.0, 3.0, 4.0]; id = 1,
                       tags = Tags("core:units" => "s"))
        d2 = Dimension(Float32[10, 20, 30, 40]; id = 2,
                       tags = Tags("core:units" => "V"))
        # Subtype, parametric eltype, AbstractVector behaviour.
        @test d1 isa SomatSIE.Dimension                # abstract supertype
        @test d1 isa SomatSIE.VectorDimension{Float64}
        @test d2 isa SomatSIE.VectorDimension{Float32}
        @test eltype(d1) === Float64
        @test length(d1) == 4
        @test size(d1) == (4,)
        @test d1[1] == 1.0
        @test d1[2:3] == [2.0, 3.0]
        @test collect(d1) == [1.0, 2.0, 3.0, 4.0]
        @test sum(d1) == 10.0                          # iterates via AbstractArray
        # Property accessors.
        @test d1.id == 1
        @test d1.tags["core:units"] == "s"

        # Build a VectorChannel via the public Channel(...) constructor.
        ch = Channel("synthetic", [d1, d2]; id = 7,
                     tags = Tags("core:sample_rate" => "100",
                                 "core:schema" => "timhis"))
        @test ch isa SomatSIE.Channel                  # abstract supertype
        @test ch isa SomatSIE.VectorChannel
        @test ch.id == 7
        @test ch.name == "synthetic"
        @test length(ch.dims) == 2
        @test ch.dims[1] === d1
        @test ch.dims[2] === d2
        @test ch.schema == "timhis"
        @test ch.sr === UInt(100)
        @test ch.tags["core:schema"] == "timhis"

        # A function typed for `Channel`/`Dimension` can consume the
        # synthetic objects without modification:
        sample_at(c::SomatSIE.Channel, i::Integer) =
            (c.dims[1][i], c.dims[2][i])
        @test sample_at(ch, 3) == (3.0, 30.0f0)

        # Reject non-AbstractDimension entries up-front.
        @test_throws ArgumentError Channel("bad", [d1, [1.0, 2.0]])

        # Empty defaults.
        d3 = Dimension(Int[])
        @test d3 isa SomatSIE.VectorDimension{Int}
        @test isempty(d3)
        @test d3.id == 1
        @test d3.tags == Tags()
    end

    @testset "In-memory types are mutable" begin
        vd = Dimension([1.0, 2.0, 3.0]; id = 1, tags = Tags("u" => "s"))
        vd.id   = 7
        vd.tags = Tags("u" => "ms")
        vd.data = [10.0, 20.0]
        @test vd.id == 7
        @test vd.tags["u"] == "ms"
        @test collect(vd) == [10.0, 20.0]
        @test length(vd) == 2

        vc = Channel("a", [vd]; id = 1)
        vc.name = "b"
        vc.id   = 2
        vc.tags = Tags("core:schema" => "timhis")
        vd2     = Dimension([0.0])
        vc.dims = SomatSIE.AbstractDimension[vd, vd2]
        @test vc.name == "b"
        @test vc.id   == 2
        @test vc.schema == "timhis"
        @test length(vc.dims) == 2

        vt = SomatSIE.Test([vc]; id = 1)
        vt.id       = 9
        vt.tags     = Tags("op" => "ef")
        vt.channels = SomatSIE.AbstractChannel[vc]
        @test vt.id == 9
        @test vt.tags["op"] == "ef"
        @test length(vt.channels) == 1
    end

    @testset "In-memory Test construction" begin
        d1 = Dimension([0.0, 0.01, 0.02, 0.03]; id = 1)
        d2 = Dimension([1.0, 2.0, 3.0, 4.0];   id = 2)
        ch1 = Channel("ch_a", [d1, d2]; id = 1,
                      tags = Tags("core:sample_rate" => "100"))
        ch2 = Channel("ch_b", [Dimension(Float32[10, 20, 30])]; id = 2)

        # Build a VectorTest via SomatSIE.Test(...).
        t = SomatSIE.Test([ch1, ch2]; id = 5,
                          tags = Tags("operator" => "ef"))
        @test t isa SomatSIE.Test            # abstract supertype
        @test t isa SomatSIE.VectorTest
        @test t.id == 5
        @test length(t.channels) == 2
        @test t.channels[1] === ch1
        @test t.channels[2] === ch2
        @test t.tags["operator"] == "ef"

        # `findchannel` works on any AbstractTest because it only uses
        # `t.channels` and `c.name`.
        @test findchannel(t, "ch_a") === ch1
        @test findchannel(t, "ch_b") === ch2
        @test findchannel(t, "missing") === nothing

        # A function typed for `Test` consumes the synthetic test:
        nrows(test::SomatSIE.Test) =
            sum(length(first(c.dims)) for c in test.channels)
        @test nrows(t) == 4 + 3

        # Reject non-AbstractChannel entries up-front.
        @test_throws ArgumentError SomatSIE.Test([ch1, "not a channel"])

        # Empty defaults.
        t0 = SomatSIE.Test(SomatSIE.AbstractChannel[])
        @test t0 isa SomatSIE.VectorTest
        @test isempty(t0.channels)
        @test t0.id == 1
        @test t0.tags == Tags()
    end

    @testset "sieDetach" begin
        # Idempotent on already-in-memory values (zero-copy: `===`).
        d  = Dimension([1.0, 2.0, 3.0]; id = 2, tags = Tags("u" => "V"))
        ch = Channel("syn", [d]; id = 1)
        tt = SomatSIE.Test([ch]; id = 1)
        @test sieDetach(d)  === d
        @test sieDetach(ch) === ch
        @test sieDetach(tt) === tt

        # Snapshot a real file: result must outlive the SieFile.
        snapshot_tests = nothing
        opensie(FILE_MIN) do f
            snapshot_tests = sieDetach(f)
            @test snapshot_tests isa Vector{SomatSIE.VectorTest}
            @test length(snapshot_tests) == length(f.tests)

            # Per-level collection.
            t = first(f.tests)
            vt = sieDetach(t)
            @test vt isa SomatSIE.VectorTest
            @test vt.id == t.id
            @test vt.tags == t.tags
            @test length(vt.channels) == length(t.channels)
            @test all(c isa SomatSIE.VectorChannel for c in vt.channels)

            c = first(t.channels)
            vc = sieDetach(c)
            @test vc isa SomatSIE.VectorChannel
            @test vc.name == c.name
            @test vc.id   == c.id
            @test vc.tags == c.tags
            @test length(vc.dims) == length(c.dims)
            @test all(d isa SomatSIE.VectorDimension for d in vc.dims)

            d0 = first(c.dims)
            vd = sieDetach(d0)
            @test vd isa SomatSIE.VectorDimension
            @test vd.id   == d0.id
            @test vd.tags == d0.tags
            @test collect(vd) == collect(d0)
            @test eltype(vd) === eltype(d0)
        end

        # `snapshot_tests` is detached \u2014 still usable after the file is closed.
        @test snapshot_tests isa Vector{SomatSIE.VectorTest}
        for vt in snapshot_tests
            for vc in vt.channels
                for vd in vc.dims
                    v = collect(vd)
                    @test v isa AbstractVector
                end
            end
        end
    end

    @testset "use-after-close raises" begin
        # Borrowed Test/Channel/Dimension references must not silently
        # dereference freed C memory after the file is closed.
        f = SieFile(FILE_MIN)
        t = first(f.tests)
        c = first(t.channels)
        d = first(c.dims)
        close(f)
        @test_throws SomatSIE.SieError t.id
        @test_throws SomatSIE.SieError t.channels
        @test_throws SomatSIE.SieError t.tags
        @test_throws SomatSIE.SieError c.id
        @test_throws SomatSIE.SieError c.name
        @test_throws SomatSIE.SieError c.dims
        @test_throws SomatSIE.SieError c.tags
        @test_throws SomatSIE.SieError d.id
        @test_throws SomatSIE.SieError d.tags
    end

end
