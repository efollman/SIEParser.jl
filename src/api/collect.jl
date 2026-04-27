# sieDetach: materialize a libsie-backed Test / Channel / Dimension (or
# any nested combination) into the in-memory `Vector*` variants. The
# returned objects are detached from the underlying `SieFile` and remain
# valid after it is closed.
#
# Idempotent: passing an already-in-memory value returns it unchanged
# (no copy), so `sieDetach` can be called freely in pipelines without
# worrying about double-allocation.

"""
    sieDetach(d::SomatSIE.Dimension) -> VectorDimension
    sieDetach(c::SomatSIE.Channel)   -> VectorChannel
    sieDetach(t::SomatSIE.Test)      -> VectorTest
    sieDetach(f::SomatSIE.SieFile)   -> Vector{VectorTest}

Materialize a libsie-backed value into its in-memory `Vector*` variant.
For a `Dimension`, all samples are read through the per-channel block
cache into a typed `Vector{T}`. For a `Channel` or `Test`, every nested
dimension is collected, producing a fully detached object that remains
valid after the source [`SieFile`](@ref) is closed.

Already in-memory values (`VectorDimension`, `VectorChannel`,
`VectorTest`) are returned unchanged \u2014 the function is idempotent
and zero-copy on that path.
# When to use
Libsie-backed dimensions already read through a per-channel block cache,
so partial / random access on large files is cheap without `sieDetach`.
Reach for `sieDetach` (or `collect(dim)` on individual dimensions)
when you plan to do substantial work on the data — filtering, FFTs,
repeated full passes — because operating on a plain `Vector` skips
the per-call cache lookup and bounds checks. It is also the right tool
when you need values to remain valid after the source `SieFile` is
closed.
```julia
opensie(\"file.sie\") do f
    snapshot = sieDetach(f)        # Vector{VectorTest}, detached
end
# `snapshot` still works here, even though `f` is closed.
```
"""
function sieDetach end

# Dimension:
sieDetach(d::VectorDimension) = d
sieDetach(d::LibSieDimension) =
    VectorDimension{eltype(d)}(collect(d), _id(d), _tags(d))

# Channel:
sieDetach(c::VectorChannel) = c
function sieDetach(c::LibSieChannel)
    dims = AbstractDimension[sieDetach(d) for d in _dimensions(c)]
    return VectorChannel(_name(c), _id(c), _tags(c), dims)
end

# Test:
sieDetach(t::VectorTest) = t
function sieDetach(t::LibSieTest)
    chs = AbstractChannel[sieDetach(c) for c in _channels(t)]
    return VectorTest(_id(t), _tags(t), chs)
end

# SieFile: collect every test. Returns a plain `Vector{VectorTest}`
# rather than a synthetic `SieFile` (we have no in-memory `SieFile`
# subtype, and a SIE file is not a meaningful concept once detached).
sieDetach(sf::SieFile) = VectorTest[sieDetach(t) for t in _tests(sf)]

# snake_case alias for callers that prefer Julia's normal naming
# convention. Identical behavior; both names are exported.
const sie_detach = sieDetach
