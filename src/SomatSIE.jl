"""
    SomatSIE

Julia bindings for [libsie-z](https://github.com/efollman/libsie-z), a library
for reading SIE files produced by HBM/Somat eDAQ acquisition equipment. The
underlying shared library is supplied by `libsie_jll`.

This is a thin, idiomatic wrapper around libsie's C ABI. The central
high-level type is:

* [`SieFile`](@ref) — an opened SIE file, opened with `open(SieFile, path)`
  and explored via [`channels`](@ref), [`tests`](@ref), [`tags`](@ref),
  [`dimensions`](@ref).

Per-dimension data is materialized with `read(file, dim)`, which returns a
typed Julia vector (`Vector{Float64}` for engineering values, or
`Vector{Vector{UInt8}}` for raw payloads such as CAN frames).

Tag values may be strings or arbitrary binary blobs — see [`Tag`](@ref).

# Example
```julia
using SomatSIE

open(SomatSIE.SieFile, "myfile.sie") do f
    @show SomatSIE.libsie_version()
    for ch in channels(f)
        for dim in dimensions(ch)
            data = read(f, dim)        # Vector{Float64} or Vector{Vector{UInt8}}
            sr = get(tags(ch), "core:sample_rate", nothing)
            println(name(ch), " dim ", id(dim), " ", length(data), " sr=", sr)
        end
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
export SieFile, Tag, Tags, SieError,
       channels, tests, tags, dimensions,
       findchannel, findtest, containingtest,
       isstring, isbinary, value, key, valuesize, group, isfromgroup,
       id, testid, name,
       libsie_version

end # module SomatSIE
