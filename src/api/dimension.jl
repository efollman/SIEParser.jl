# Dimension:
"""
    AbstractDimension{T} <: AbstractVector{T}
    const Dimension = AbstractDimension

A single axis ("column") of a [`Channel`](@ref). Two concrete subtypes:

* [`LibSieDimension{T}`](@ref) — backed by a libsie handle on an open
  [`SieFile`](@ref). Reads are routed through a per-channel block cache
  so random/range access only decodes the necessary blocks. Element type
  is determined by probing the channel: `Float64` for engineering-value
  columns, `Vector{UInt8}` for raw payload columns (e.g. CAN frames).
* [`VectorDimension{T}`](@ref) — backed by an in-memory `Vector{T}`.
  Cheap to construct from edited or synthetic data, and lets functions
  written for `Channel`/`Dimension` consume hand-built input.

Both behave as proper `AbstractVector{T}`s — `dim[i]`, `dim[a:b]`,
`collect(dim)`, iteration, and pass-through to DataFrames / Makie all
work. Identity and metadata: `dim.id` (1-based), `dim.tags`.

Construct an in-memory dimension via:

    Dimension(data::AbstractVector; id=1, tags=Tags()) -> VectorDimension
"""
abstract type AbstractDimension{T} <: AbstractVector{T} end

const Dimension = AbstractDimension

"""
    LibSieDimension{T} <: AbstractDimension{T}

A `Dimension` backed by a libsie handle on an open [`SieFile`](@ref).
Constructed only by the library; reads are cached per-channel.
"""
struct LibSieDimension{T} <: AbstractDimension{T}
    handle::Ptr{Cvoid}
    parent::Any  # LibSieChannel — typed Any to avoid forward declaration
end

"""
    VectorDimension{T} <: AbstractDimension{T}

A `Dimension` whose samples live in a regular Julia `Vector{T}`. Build
one with `Dimension(data; id=1, tags=Tags())`. Mutable: `vd.id`,
`vd.tags`, and `vd.data` may all be reassigned.
"""
mutable struct VectorDimension{T} <: AbstractDimension{T}
    data::Vector{T}
    id::Int
    tags::Tags
end

# Public outer constructor — `Dimension(data; ...)` resolves through the
# `const Dimension = AbstractDimension` alias to this method.
function (::Type{AbstractDimension})(data::AbstractVector;
                                     id::Integer = 1, tags::Tags = Tags())
    v = data isa Vector ? data : collect(data)
    T = eltype(v)
    return VectorDimension{T}(v, Int(id), tags)
end

# Internal accessors — split per concrete type:
_id(d::LibSieDimension)   = Int(L.sie_dimension_index(d.handle)) + 1
_tags(d::LibSieDimension) = _build_tags(d.handle,
    Int(L.sie_dimension_num_tags(d.handle)), L.sie_dimension_tag)

_id(d::VectorDimension)   = d.id
_tags(d::VectorDimension) = d.tags

function Base.getproperty(d::LibSieDimension, sym::Symbol)
    sym === :id   && return _id(d)
    sym === :tags && return _tags(d)
    return getfield(d, sym)
end
function Base.getproperty(d::VectorDimension, sym::Symbol)
    return getfield(d, sym)   # id, tags, data are real fields
end
Base.propertynames(::AbstractDimension, private::Bool = false) =
    private ? (:id, :tags) : (:id, :tags)

Base.show(io::IO, d::AbstractDimension) =
    print(io, "Dimension{", eltype(d), "}(id=", _id(d), ", n=", length(d), ")")

# ── VectorDimension: AbstractArray interface (delegates to backing data) ──
Base.size(d::VectorDimension)             = size(d.data)
Base.IndexStyle(::Type{<:VectorDimension}) = IndexLinear()
Base.@propagate_inbounds Base.getindex(d::VectorDimension, i::Integer) = d.data[i]

# ── LibSieDimension: cache-routed access ──
#
# `LibSieDimension <: AbstractVector{T}`, so `firstindex`, `lastindex`,
# `size`, `eltype`, `IndexStyle`, etc. come from Base. We override the
# methods below to route through the per-channel block cache instead of
# falling back to per-element scalar reads:
#
#   length(dim)         total sample count (from cache)
#   dim[i]              one sample — only the containing block is fetched
#   dim[a:b]            sub-range — only the overlapping blocks are fetched
#   dim[:] / collect    full materialized vector via the cache
#   for x in dim ...    iterates the materialized vector

# Forward declarations satisfied later in the load order:
#   ChannelCache, _channel_cache, _block_for, _locate_row, _readdim

Base.size(d::LibSieDimension) =
    (_channel_cache(d.parent.parent::SieFile,
                    d.parent::LibSieChannel).total_rows,)

# Full materialization. Walks the channel via the persistent spigot,
# decoding each block once via the libsie bulk range getters and caching
# the result in the per-channel block LRU. Subsequent index/range/collect
# calls hit the cache and avoid any new ccalls.
Base.collect(d::LibSieDimension)            = _readdim(d)
Base.getindex(d::LibSieDimension, ::Colon)  = _readdim(d)

# Single-sample read. Translates the row index to (block_idx, row_in_block)
# via the cached cumulative-row offsets (binary search on a small `Vector`),
# then fetches the containing block from the cache (or decodes it once and
# stores it).
function Base.getindex(d::LibSieDimension, i::Integer)
    i >= 1 || throw(BoundsError(d, i))
    ch    = d.parent::LibSieChannel
    file  = ch.parent::SieFile
    cache = _channel_cache(file, ch)
    Int(i) > cache.total_rows && throw(BoundsError(d, i))
    block_idx, row_in_block = _locate_row(cache, Int(i) - 1)
    data = _block_for(cache, _id(d), block_idx)
    return data[row_in_block + 1]
end

# Range read. Walks only the blocks overlapping the requested range. Each
# such block is fetched through the cache (decoded once, then memoized), so
# repeated `dim[a:b]` calls over the same neighborhood pay no further
# decoding cost.
function Base.getindex(d::LibSieDimension, r::AbstractUnitRange{<:Integer})
    if isempty(r)
        return eltype(d) === Float64 ? Float64[] : Vector{UInt8}[]
    end
    first(r) >= 1 || throw(BoundsError(d, first(r)))
    ch    = d.parent::LibSieChannel
    file  = ch.parent::SieFile
    cache = _channel_cache(file, ch)
    Int(last(r)) > cache.total_rows && throw(BoundsError(d, last(r)))
    dimid = _id(d)
    lo0   = Int(first(r)) - 1   # 0-based, inclusive
    hi0   = Int(last(r))  - 1   # 0-based, inclusive
    blo, _ = _locate_row(cache, lo0)
    bhi, _ = _locate_row(cache, hi0)
    et = eltype(d)
    result = et === Float64 ? Vector{Float64}(undef, length(r)) :
                              Vector{Vector{UInt8}}(undef, length(r))
    pos = 1
    @inbounds for b in blo:bhi
        block = _block_for(cache, dimid, b)
        block_start0 = cache.offsets[b]
        block_end0   = cache.offsets[b + 1] - 1
        local_lo = max(lo0, block_start0) - block_start0
        local_hi = min(hi0, block_end0)   - block_start0
        n = local_hi - local_lo + 1
        for k in 0:(n - 1)
            result[pos + k] = block[local_lo + 1 + k]
        end
        pos += n
    end
    return result
end

# Iteration: materialize once with `collect` and walk the resulting vector.
# Cheaper than per-element indexing (which would touch the cache per call).
# `VectorDimension` inherits the default AbstractArray iterate, which is
# already a single array index per step — no override needed there.
function Base.iterate(d::LibSieDimension)
    v = collect(d)
    return isempty(v) ? nothing : (v[1], (v, 2))
end
function Base.iterate(::LibSieDimension, state)
    v, i = state
    return i > length(v) ? nothing : (v[i], (v, i + 1))
end
