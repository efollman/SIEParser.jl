# Channel:
"""
    AbstractChannel
    const Channel = AbstractChannel

A data series within a [`SieFile`](@ref). Two concrete subtypes:

* [`LibSieChannel`](@ref) — backed by a libsie handle on an open
  [`SieFile`](@ref). All metadata and dimension data come from the file.
* [`VectorChannel`](@ref) — backed by hand-built dimensions
  ([`VectorDimension`](@ref) or any other `AbstractDimension`). Lets you
  pass synthetic / edited data to functions written against `Channel`.

Access via dot syntax on either subtype: `ch.id`, `ch.name`, `ch.dims`,
`ch.tags`, plus the convenience accessors `ch.schema` (the `core:schema`
tag, or `nothing`) and `ch.sr` (the `core:sample_rate` tag parsed as
`UInt`, falling back to `Float64`, or `nothing` if unset).

Construct an in-memory channel via:

    Channel(name::AbstractString, dims::AbstractVector{<:AbstractDimension};
            id=1, tags=Tags()) -> VectorChannel
"""
abstract type AbstractChannel end

const Channel = AbstractChannel

"""
    LibSieChannel <: AbstractChannel

A `Channel` backed by a libsie handle on an open [`SieFile`](@ref).
Constructed only by the library.
"""
struct LibSieChannel <: AbstractChannel
    handle::Ptr{Cvoid}
    parent::Any   # keeps SieFile alive
end

"""
    VectorChannel <: AbstractChannel

A `Channel` whose dimensions are held in a regular Julia vector. Build
one with `Channel(name, dims; id=1, tags=Tags())`. Mutable: `vc.name`,
`vc.id`, `vc.tags`, and `vc.dims` may all be reassigned.
"""
mutable struct VectorChannel <: AbstractChannel
    name::String
    id::Int
    tags::Tags
    dims::Vector{AbstractDimension}
end

# Public outer constructor — `Channel(name, dims; ...)` resolves through
# the `const Channel = AbstractChannel` alias to this method.
function (::Type{AbstractChannel})(name::AbstractString,
                                   dims::AbstractVector;
                                   id::Integer = 1, tags::Tags = Tags())
    ds = Vector{AbstractDimension}(undef, length(dims))
    @inbounds for (i, d) in enumerate(dims)
        d isa AbstractDimension || throw(ArgumentError(
            "Channel dims must be `AbstractDimension`s; got $(typeof(d))"))
        ds[i] = d
    end
    return VectorChannel(String(name), Int(id), tags, ds)
end

_id(c::LibSieChannel)       = Int(L.sie_channel_id(c.handle)) + 1
_name(c::LibSieChannel)     = _ptrlen_to_string(L.sie_channel_name, c.handle)
_numdims(c::LibSieChannel)  = Int(L.sie_channel_num_dims(c.handle))
_tags(c::LibSieChannel)     = _build_tags(c.handle,
    Int(L.sie_channel_num_tags(c.handle)), L.sie_channel_tag)

_id(c::VectorChannel)       = c.id
_name(c::VectorChannel)     = c.name
_numdims(c::VectorChannel)  = length(c.dims)
_tags(c::VectorChannel)     = c.tags

# `core:schema` tag, or `nothing` if absent. Polymorphic over both subtypes.
_schema(c::AbstractChannel) = get(_tags(c), "core:schema", nothing)

# `core:sample_rate` tag parsed as a number, or `nothing` if absent.
# Tries `UInt` first; falls back to `Float64` for non-integer rates.
# `Vector{UInt8}` tag values are interpreted as UTF-8 first.
function _sample_rate(c::AbstractChannel)
    v = get(_tags(c), "core:sample_rate", nothing)
    v === nothing && return nothing
    s = v isa AbstractString ? v : String(copy(v))
    u = tryparse(UInt, s)
    u !== nothing && return u
    return tryparse(Float64, s)
end

function _dimension(c::LibSieChannel, i::Integer)
    1 <= i <= _numdims(c) || throw(BoundsError(c, i))
    h = L.sie_channel_dimension(c.handle, i - 1)
    h == C_NULL && throw(BoundsError(c, i))
    T = _probe_dim_eltypes(c, _numdims(c))[i]
    return LibSieDimension{T}(h, c)
end

function _dimensions(c::LibSieChannel)
    n = _numdims(c)
    types = _probe_dim_eltypes(c, n)
    out = Vector{AbstractDimension}(undef, n)
    @inbounds for i in 1:n
        h = L.sie_channel_dimension(c.handle, i - 1)
        h == C_NULL && throw(BoundsError(c, i))
        out[i] = LibSieDimension{types[i]}(h, c)
    end
    return out
end

_dimension(c::VectorChannel, i::Integer)  = (1 <= i <= length(c.dims) ||
    throw(BoundsError(c, i)); c.dims[i])
_dimensions(c::VectorChannel)             = c.dims

# Probe the element types of all dimensions of a channel by attaching a
# transient spigot, reading the type tag of the first block, and freeing.
# Empty channels (no blocks) fall back to `Float64` so that downstream
# `Vector{Float64}` allocations remain well-defined.
function _probe_dim_eltypes(c::LibSieChannel, n::Int)
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

function Base.getproperty(c::LibSieChannel, sym::Symbol)
    sym === :id         && return _id(c)
    sym === :name       && return _name(c)
    sym === :dims       && return _dimensions(c)
    sym === :tags       && return _tags(c)
    sym === :schema     && return _schema(c)
    sym === :sr         && return _sample_rate(c)
    return getfield(c, sym)
end
function Base.getproperty(c::VectorChannel, sym::Symbol)
    sym === :schema     && return _schema(c)
    sym === :sr         && return _sample_rate(c)
    return getfield(c, sym)   # id, name, dims, tags are real fields
end
Base.propertynames(::AbstractChannel, private::Bool = false) =
    (:id, :name, :dims, :tags, :schema, :sr)

Base.show(io::IO, c::AbstractChannel) =
    print(io, "Channel(id=", _id(c), ", name=", repr(_name(c)),
              ", ndims=", _numdims(c), ")")
