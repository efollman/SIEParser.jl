# Internal-API tests for SomatSIE.jl.
#
# These pin behavior of unexported helpers that are NOT part of the
# documented surface (`spigot`, `Spigot`, `Output`, `next!`, `numrows`,
# `numdims`, `numblocks`, `block`, `coltype`, `getfloat64`, `reset!`).
# Refactors that delete or rename these helpers will need to update or
# delete this file. Public-API behavior lives in `test_public.jl`.

using Test
using SomatSIE
using SomatSIE: SieFile, Spigot, Output,
                opensie,
                spigot,
                next!, numrows, numdims, numblocks, block, coltype,
                getfloat64,
                reset!

@testset "Internal API" begin

    @testset "spigot iteration" begin
        opensie(FILE_MIN) do f
            ch = first(first(f.tests).channels)
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
                    first_idx = block(first_block)   # snapshot before reset!
                    reset!(s)
                    @test position(s) >= 0
                    again = next!(s)
                    @test again !== nothing
                    @test block(again) == first_idx
                end
            finally
                close(s)
            end
        end
    end

    @testset "Output invalidation after spigot advance" begin
        opensie(FILE_MIN) do f
            ch = first(first(f.tests).channels)
            spigot(f, ch) do s
                first_block = next!(s)
                if first_block !== nothing
                    # Advancing or resetting the spigot invalidates prior Outputs.
                    second_block = next!(s)
                    @test_throws ErrorException numrows(first_block)
                    @test_throws ErrorException block(first_block)
                    @test_throws ErrorException coltype(first_block, 1)
                    if second_block !== nothing
                        reset!(s)
                        @test_throws ErrorException numrows(second_block)
                    end
                end
            end
        end
    end

end
