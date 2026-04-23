"""
    SomatSIE

Julia bindings for [libsie-z](https://github.com/efollman/libsie-z), a library
for reading SIE files produced by HBM/Somat eDAQ acquisition equipment. The
underlying shared library is supplied by `libsie_jll`.

This is a thin, idiomatic wrapper around libsie's C ABI. The two important
high-level types are:

* [`SieFile`](@ref) — an opened SIE file, opened with `open(SieFile, path)`
  and explored via [`channels`](@ref), [`tests`](@ref), [`tags`](@ref).
* [`Spigot`](@ref) — a per-channel data pipeline. Iterate it for streaming
  [`Output`](@ref) blocks, or call `read(file, channel)` to get a `Matrix`.

Tag values may be strings or arbitrary binary blobs — see [`Tag`](@ref).

# Example
```julia
using SomatSIE

open(SomatSIE.SieFile, "myfile.sie") do f
    @show SomatSIE.libsie_version()
    for ch in channels(f)
        data = read(f, ch)         # Matrix{Float64}, (rows, dims)
        sr = get(tags(ch), "core:sample_rate", nothing)
        println(name(ch), " ", size(data), " sr=", sr)
    end
end
```

# Limitations
The C ABI exposed by `libsie_jll` (v0.3) is read-only — there is no SIE file
writer at this time.
"""
module SomatSIE

include("ccalls.jl")
include("api.jl")

# Public surface
export SieFile, Spigot, Stream, Histogram, Tag, Tags, Output, SieError,
       channels, tests, tags, dimensions, dimension, channel, test,
       findchannel, findtest, containingtest,
       spigot, next!, numblocks, numrows, numdims, block, coltype,
       getfloat64, getraw,
       isstring, isbinary, value, key, valuesize, group, isfromgroup,
       id, testid, name, index, nchannels, ntests,
       reset!, disable_transforms!, set_scan_limit!,
       add!, numgroups, group_numblocks, group_numbytes, group_isclosed,
       numbins, totalsize, getbin, bounds,
       libsie_version

end # module SomatSIE
