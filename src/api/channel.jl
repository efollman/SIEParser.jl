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
    h == C_NULL && throw(BoundsError(c, i))
    T = _probe_dim_eltypes(c, _numdims(c))[i]
    return Dimension{T}(h, c)
end

function _dimensions(c::Channel)
    n = _numdims(c)
    types = _probe_dim_eltypes(c, n)
    out = Vector{Dimension}(undef, n)
    @inbounds for i in 1:n
        h = L.sie_channel_dimension(c.handle, i - 1)
        h == C_NULL && throw(BoundsError(c, i))
        out[i] = Dimension{types[i]}(h, c)
    end
    return out
end

# Probe the element types of all dimensions of a channel by attaching a
# transient spigot, reading the type tag of the first block, and freeing.
# Empty channels (no blocks) fall back to `Float64` so that downstream
# `Vector{Float64}` allocations remain well-defined.
function _probe_dim_eltypes(c::Channel, n::Int)
    file = c.parent::SieFile
    types = fill(Float64, n)::Vector{DataType}
    spig_ref = Ref{Ptr{Cvoid}}(C_NULL)
    s = L.sie_spigot_attach(file.handle, c.handle, spig_ref)
    s == L.SIE_OK || return types
    sp = spig_ref[]
    try
        out_ref = Ref{Ptr{Cvoid}}(C_NULL)
        s = L.sie_spigot_get(sp, out_ref)
        s == L.SIE_OK || return types
        outh = out_ref[]
        @inbounds for i in 1:n
            t = L.sie_output_type(outh, Csize_t(i - 1))
            types[i] = t == L.SIE_OUTPUT_FLOAT64 ? Float64       :
                       t == L.SIE_OUTPUT_RAW     ? Vector{UInt8} :
                                                   Float64
        end
    finally
        L.sie_spigot_free(sp)
    end
    return types
end

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
