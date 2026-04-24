"""
    SomatSIE

Julia bindings for [libsie-z](https://github.com/efollman/libsie-z), a library
for reading SIE files produced by HBM/Somat eDAQ acquisition equipment. The
underlying shared library is supplied by `libsie_jll`.

This is a thin, idiomatic wrapper around libsie's C ABI. The central
high-level type is:

* [`SieFile`](@ref) — an opened SIE file, opened with [`opensie`](@ref) and
  explored via dot-property accessors (`f.tests`, `t.channels`,
  `ch.dimensions`, `x.tags`, `x.id`, `x.name`).

Per-dimension data is materialized with [`readDim`](@ref), which returns a
typed Julia vector (`Vector{Float64}` for engineering values, or
`Vector{Vector{UInt8}}` for raw payloads such as CAN frames).

Tag values may be strings or arbitrary binary blobs — `x.tags` returns a
`Dict{String, Union{String, Vector{UInt8}}}` ([`Tags`](@ref)).

# Example
```julia
using SomatSIE

opensie("myfile.sie") do f
    @show SomatSIE.libsie_version()
    for t in f.tests, ch in t.channels
        for dim in ch.dimensions
            data = readDim(dim)        # Vector{Float64} or Vector{Vector{UInt8}}
            sr = get(ch.tags, "core:sample_rate", nothing)
            println(ch.name, " dim ", dim.id, " ", length(data), " sr=", sr)
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
export SieFile, Tags, SieError,
       opensie, readDim,
       findchannel,
       libsie_version

end # module SomatSIE
