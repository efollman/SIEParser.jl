# Channel:
"""
    Channel

A data series within a [`SieFile`](@ref). Borrowed from the file.

Access via dot syntax: `ch.id`, `ch.name`, `ch.dims`, `ch.tags`, plus the
convenience accessors `ch.schema` (the `core:schema` tag, or `nothing`)
and `ch.sr` (the `core:sample_rate` tag parsed as `UInt`, falling back to
`Float64`, or `nothing` if unset).
"""
struct Channel
    handle::Ptr{Cvoid}
    parent::Any   # keeps SieFile alive
end

_id(c::Channel)       = Int(L.sie_channel_id(c.handle)) + 1
_name(c::Channel)     = _ptrlen_to_string(L.sie_channel_name, c.handle)
_numdims(c::Channel)  = Int(L.sie_channel_num_dims(c.handle))
_tags(c::Channel)     = _build_tags(c.handle,
    Int(L.sie_channel_num_tags(c.handle)), L.sie_channel_tag)

# `core:schema` tag, or `nothing` if absent. Returned as-is from the tag
# dict (typically a `String`).
function _schema(c::Channel)
    v = get(_tags(c), "core:schema", nothing)
    return v
end

# `core:sample_rate` tag parsed as a number, or `nothing` if absent.
# Tries `UInt` first; falls back to `Float64` for non-integer rates.
# `Vector{UInt8}` tag values are interpreted as UTF-8 first.
function _sample_rate(c::Channel)
    v = get(_tags(c), "core:sample_rate", nothing)
    v === nothing && return nothing
    s = v isa AbstractString ? v : String(copy(v))
    u = tryparse(UInt, s)
    u !== nothing && return u
    return tryparse(Float64, s)
end

function _dimension(c::Channel, i::Integer)
    1 <= i <= _numdims(c) || throw(BoundsError(c, i))
    h = L.sie_channel_dimension(c.handle, i - 1)
    h == C_NULL ? throw(BoundsError(c, i)) : Dimension(h, c)
end

_dimensions(c::Channel) = [_dimension(c, i) for i in 1:_numdims(c)]

function Base.getproperty(c::Channel, sym::Symbol)
    sym === :id         && return _id(c)
    sym === :name       && return _name(c)
    sym === :dims       && return _dimensions(c)
    sym === :tags       && return _tags(c)
    sym === :schema     && return _schema(c)
    sym === :sr         && return _sample_rate(c)
    return getfield(c, sym)
end
Base.propertynames(::Channel, private::Bool = false) =
    private ? (:id, :name, :dims, :tags, :schema, :sr, :handle, :parent) :
              (:id, :name, :dims, :tags, :schema, :sr)

Base.show(io::IO, c::Channel) =
    print(io, "Channel(id=", _id(c), ", name=", repr(_name(c)),
              ", ndims=", _numdims(c), ")")
