# sieCollect: materialize a libsie-backed Test / Channel / Dimension (or
# any nested combination) into the in-memory `Vector*` variants. The
# returned objects are detached from the underlying `SieFile` and remain
# valid after it is closed.
#
# Idempotent: passing an already-in-memory value returns it unchanged
# (no copy), so `sieCollect` can be called freely in pipelines without
# worrying about double-allocation.

"""
    sieCollect(d::SomatSIE.Dimension) -> VectorDimension
    sieCollect(c::SomatSIE.Channel)   -> VectorChannel
    sieCollect(t::SomatSIE.Test)      -> VectorTest
    sieCollect(f::SomatSIE.SieFile)   -> Vector{VectorTest}

Materialize a libsie-backed value into its in-memory `Vector*` variant.
For a `Dimension`, all samples are read through the per-channel block
cache into a typed `Vector{T}`. For a `Channel` or `Test`, every nested
dimension is collected, producing a fully detached object that remains
valid after the source [`SieFile`](@ref) is closed.

Already in-memory values (`VectorDimension`, `VectorChannel`,
`VectorTest`) are returned unchanged \u2014 the function is idempotent
and zero-copy on that path.

```julia
opensie(\"file.sie\") do f
    snapshot = sieCollect(f)        # Vector{VectorTest}, detached
end
# `snapshot` still works here, even though `f` is closed.
```
"""
function sieCollect end

# Dimension:
sieCollect(d::VectorDimension) = d
sieCollect(d::LibSieDimension) =
    VectorDimension{eltype(d)}(collect(d), _id(d), _tags(d))

# Channel:
sieCollect(c::VectorChannel) = c
function sieCollect(c::LibSieChannel)
    dims = AbstractDimension[sieCollect(d) for d in _dimensions(c)]
    return VectorChannel(_name(c), _id(c), _tags(c), dims)
end

# Test:
sieCollect(t::VectorTest) = t
function sieCollect(t::LibSieTest)
    chs = AbstractChannel[sieCollect(c) for c in _channels(t)]
    return VectorTest(_id(t), _tags(t), chs)
end

# SieFile: collect every test. Returns a plain `Vector{VectorTest}`
# rather than a synthetic `SieFile` (we have no in-memory `SieFile`
# subtype, and a SIE file is not a meaningful concept once detached).
sieCollect(sf::SieFile) = VectorTest[sieCollect(t) for t in _tests(sf)]
