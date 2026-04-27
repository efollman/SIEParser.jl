# Test:
"""
    AbstractTest
    const Test = AbstractTest

A test (acquisition session). Two concrete subtypes:

* [`LibSieTest`](@ref) \u2014 backed by a libsie handle on an open
  [`SieFile`](@ref).
* [`VectorTest`](@ref) \u2014 backed by a vector of in-memory channels.
  Lets you pass synthetic / edited tests to functions written against
  `Test`.

Access via dot syntax on either subtype: `t.id`, `t.channels`, `t.tags`.

Construct an in-memory test via:

    SomatSIE.Test(channels::AbstractVector{<:AbstractChannel};
                  id=1, tags=Tags()) -> VectorTest

`Test` is unexported; access it as `SomatSIE.Test` to avoid clashing
with `Test.Test` from the standard library.
"""
abstract type AbstractTest end

const Test = AbstractTest

"""
    LibSieTest <: AbstractTest

A `Test` backed by a libsie handle on an open [`SieFile`](@ref).
Constructed only by the library.
"""
struct LibSieTest <: AbstractTest
    handle::Ptr{Cvoid}
    parent::Any   # keeps SieFile alive
end

"""
    VectorTest <: AbstractTest

A `Test` whose channels are held in a regular Julia vector. Build one
with `SomatSIE.Test(channels; id=1, tags=Tags())`. Mutable: `vt.id`,
`vt.tags`, and `vt.channels` may all be reassigned.
"""
mutable struct VectorTest <: AbstractTest
    id::Int
    tags::Tags
    channels::Vector{AbstractChannel}
end

# Public outer constructor \u2014 `SomatSIE.Test(channels; ...)` resolves
# through the `const Test = AbstractTest` alias to this method.
function (::Type{AbstractTest})(channels::AbstractVector;
                                id::Integer = 1, tags::Tags = Tags())
    cs = Vector{AbstractChannel}(undef, length(channels))
    @inbounds for (i, c) in enumerate(channels)
        c isa AbstractChannel || throw(ArgumentError(
            "Test channels must be `AbstractChannel`s; got $(typeof(c))"))
        cs[i] = c
    end
    return VectorTest(Int(id), tags, cs)
end

_id(t::LibSieTest)        = Int(L.sie_test_id(t.handle)) + 1
_nchannels(t::LibSieTest) = Int(L.sie_test_num_channels(t.handle))
_tags(t::LibSieTest)      = _build_tags(t.handle,
    Int(L.sie_test_num_tags(t.handle)), L.sie_test_tag)

_id(t::VectorTest)        = t.id
_nchannels(t::VectorTest) = length(t.channels)
_tags(t::VectorTest)      = t.tags

function _channel(t::LibSieTest, i::Integer)
    1 <= i <= _nchannels(t) || throw(BoundsError(t, i))
    h = L.sie_test_channel(t.handle, i - 1)
    h == C_NULL ? throw(BoundsError(t, i)) : LibSieChannel(h, t.parent)
end

_channels(t::LibSieTest) = [_channel(t, i) for i in 1:_nchannels(t)]

_channel(t::VectorTest, i::Integer)  = (1 <= i <= length(t.channels) ||
    throw(BoundsError(t, i)); t.channels[i])
_channels(t::VectorTest)             = t.channels

function Base.getproperty(t::LibSieTest, sym::Symbol)
    sym === :id       && return _id(t)
    sym === :channels && return _channels(t)
    sym === :tags     && return _tags(t)
    return getfield(t, sym)
end
function Base.getproperty(t::VectorTest, sym::Symbol)
    return getfield(t, sym)   # id, channels, tags are real fields
end
Base.propertynames(::AbstractTest, private::Bool = false) =
    (:id, :channels, :tags)

Base.show(io::IO, t::AbstractTest) =
    print(io, "Test(id=", _id(t),
              ", nchannels=", _nchannels(t), ")")
