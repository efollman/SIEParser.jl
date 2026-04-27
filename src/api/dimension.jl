# Dimension:
"""
    Dimension{T} <: AbstractVector{T}

A single axis ("column") of a [`Channel`](@ref). Borrowed from the channel.

`Dimension` is a proper `AbstractVector` whose element type is determined
at construction by probing the underlying channel: `Dimension{Float64}`
for engineering-value columns, `Dimension{Vector{UInt8}}` for raw
payload columns (e.g. CAN frames). Empty channels default to `Float64`.

Because it is an `AbstractVector`, you can pass a `Dimension` directly to
any interface that consumes vectors — `DataFrame(:t => dim)`, Makie
plot recipes, etc. — without an explicit `collect`. Indexing follows
the usual semantics:

* `dim[i]` returns a single sample (reading only the block that contains it),
* `dim[a:b]` returns a range (reading only the overlapping blocks),
* `collect(dim)` (or `dim[:]`) materializes the entire data series as a
  typed Julia vector.

Access identity and metadata via dot syntax: `dim.id`, `dim.tags`.
`dim.id` is **1-based** (1 is typically time, 2 is value for sequential
time-series channels).
"""
struct Dimension{T} <: AbstractVector{T}
    handle::Ptr{Cvoid}
    parent::Any  # Channel — typed Any to avoid forward declaration; see ch field below
end

_id(d::Dimension)   = Int(L.sie_dimension_index(d.handle)) + 1
_tags(d::Dimension) = _build_tags(d.handle,
    Int(L.sie_dimension_num_tags(d.handle)), L.sie_dimension_tag)

function Base.getproperty(d::Dimension, sym::Symbol)
    sym === :id   && return _id(d)
    sym === :tags && return _tags(d)
    return getfield(d, sym)
end
Base.propertynames(::Dimension, private::Bool = false) =
    private ? (:id, :tags, :handle, :parent) : (:id, :tags)

Base.show(io::IO, d::Dimension) =
    print(io, "Dimension{", eltype(d), "}(", _id(d), ")")

# Vector-like access on Dimension:
#
# `Dimension <: AbstractVector{T}`, so `firstindex`, `lastindex`, `size`,
# `eltype`, `IndexStyle`, etc. come from Base. We only override the methods
# below to route through the per-channel block cache instead of falling
# back to per-element scalar reads:
#
#   length(dim)         total sample count (from cache)
#   dim[i]              one sample — only the containing block is fetched
#   dim[a:b]            sub-range — only the overlapping blocks are fetched
#   dim[:] / collect    full materialized vector via the cache
#   for x in dim ...    iterates the materialized vector

# Forward declarations satisfied later in this file:
#   ChannelCache, _channel_cache, _block_for, _locate_row

Base.size(d::Dimension)       = (_channel_cache(d.parent.parent::SieFile,
                                                 d.parent::Channel).total_rows,)

# Full materialization. Walks the channel via the persistent spigot,
# decoding each block once via the libsie bulk range getters and caching
# the result in the per-channel block LRU. Subsequent index/range/collect
# calls hit the cache and avoid any new ccalls.
Base.collect(d::Dimension)            = _readdim(d)
Base.getindex(d::Dimension, ::Colon)  = _readdim(d)

# Single-sample read. Translates the row index to (block_idx, row_in_block)
# via the cached cumulative-row offsets (binary search on a small `Vector`),
# then fetches the containing block from the cache (or decodes it once and
# stores it).
function Base.getindex(d::Dimension, i::Integer)
    i >= 1 || throw(BoundsError(d, i))
    ch    = d.parent::Channel
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
function Base.getindex(d::Dimension, r::AbstractUnitRange{<:Integer})
    if isempty(r)
        return eltype(d) === Float64 ? Float64[] : Vector{UInt8}[]
    end
    first(r) >= 1 || throw(BoundsError(d, first(r)))
    ch    = d.parent::Channel
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
# Cheaper than per-element indexing (which reopens a spigot per call) and
# avoids the bookkeeping of holding a long-lived spigot across `iterate`
# boundaries.
function Base.iterate(d::Dimension)
    v = collect(d)
    return isempty(v) ? nothing : (v[1], (v, 2))
end
function Base.iterate(::Dimension, state)
    v, i = state
    return i > length(v) ? nothing : (v[i], (v, i + 1))
end
