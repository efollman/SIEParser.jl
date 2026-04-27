# Test:
"""
    Test

A test (acquisition session) within a [`SieFile`](@ref). Borrowed from the
file. Named `Test` for SIE convention; access as `SomatSIE.Test` to avoid
collision with `Base.Test`.
"""
struct Test
    handle::Ptr{Cvoid}
    parent::Any   # keeps SieFile alive
end

_id(t::Test)        = Int(L.sie_test_id(t.handle)) + 1
_nchannels(t::Test) = Int(L.sie_test_num_channels(t.handle))
_tags(t::Test)      = _build_tags(t.handle,
    Int(L.sie_test_num_tags(t.handle)), L.sie_test_tag)

function _channel(t::Test, i::Integer)
    1 <= i <= _nchannels(t) || throw(BoundsError(t, i))
    h = L.sie_test_channel(t.handle, i - 1)
    h == C_NULL ? throw(BoundsError(t, i)) : Channel(h, t.parent)
end

_channels(t::Test) = [_channel(t, i) for i in 1:_nchannels(t)]

function Base.getproperty(t::Test, sym::Symbol)
    sym === :id       && return _id(t)
    sym === :channels && return _channels(t)
    sym === :tags     && return _tags(t)
    return getfield(t, sym)
end
Base.propertynames(::Test, private::Bool = false) =
    private ? (:id, :channels, :tags, :handle, :parent) :
              (:id, :channels, :tags)

Base.show(io::IO, t::Test) =
    print(io, "Test(id=", _id(t),
              ", nchannels=", _nchannels(t), ")")
