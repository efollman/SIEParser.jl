"""
    SomatSIE

Julia bindings for [libsie-z](https://github.com/efollman/libsie-z), a library
for reading SIE files produced by HBM/Somat eDAQ acquisition equipment. The
underlying shared library is supplied by `libsie_jll`.

This is a thin, idiomatic wrapper around libsie's C ABI. The central
high-level type is:

* [`SieFile`](@ref) — an opened SIE file, opened with [`opensie`](@ref) and
  explored via dot-property accessors (`f.tests`, `t.channels`,
  `ch.dims`, `x.tags`, `x.id`, `ch.name`).

Per-dimension data is accessed by indexing the [`Dimension`](@ref):
`dim[i]` (single sample, fetches only the containing block), `dim[a:b]`
(range, fetches only the overlapping blocks), or `collect(dim)` /
`dim[:]` for the full series — returning a typed Julia vector
(`Vector{Float64}` for engineering values, or `Vector{Vector{UInt8}}`
for raw payloads such as CAN frames).

# Caching vs. materializing
Libsie-backed dimensions read through a per-channel block cache, so
partial / random access on large files is cheap — only the touched
blocks are decoded, and re-touching the same neighborhood is free. For
substantial work on a channel's data (filtering, FFTs, repeated full
passes), call `collect(dim)` once and operate on the resulting plain
`Vector`, or use [`sieDetach`](@ref) to detach an entire `Test` /
`Channel` / `SieFile` into the in-memory `Vector*` variants up front.
Rule of thumb: small files or whole-channel work → `sieDetach`;
large files with sparse access → leave the `SieFile` open and let
the cache do its job.

Tag values may be strings or arbitrary binary blobs — `x.tags` returns a
`Dict{String, Union{String, Vector{UInt8}}}` ([`Tags`](@ref)).

# Example
```julia
using SomatSIE

opensie("myfile.sie") do f
    for t in f.tests, ch in t.channels
        for dim in ch.dims
            data = collect(dim)        # Vector{Float64} or Vector{Vector{UInt8}}
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

using .LibSIE
const L = LibSIE

# High-level Julia API for libsie.
#
# Provides Julia-idiomatic types backed by libsie's opaque handles plus
# `open`/`close`, iteration, indexing, and `read` semantics that should feel
# natural to Julia users.
include("api/errors.jl")
include("api/tags.jl")
include("api/dimension.jl")
include("api/channel.jl")
include("api/test.jl")
include("api/file.jl")
include("api/output.jl")
include("api/spigot.jl")
include("api/cache.jl")
include("api/collect.jl")

# Public surface
#
# Types are intentionally NOT exported — access them as
# `SomatSIE.SieFile`, `SomatSIE.Tags`, `SomatSIE.SieError`,
# `SomatSIE.Test`, `SomatSIE.Channel`, `SomatSIE.Dimension`. This
# avoids name collisions with `Base.Channel` (Tasks), `Test.Test` (the
# stdlib testing module), and any user-defined `SieFile`/`Tags`/`Dimension`.
# Only the verbs `opensie` and `findchannel` are exported.
export opensie,
       findchannel,
       sieDetach

end # module SomatSIE
