# Dimension:
"""
    Dimension

A single axis ("column") of a [`Channel`](@ref). Borrowed from the channel.

Access identity and metadata via dot syntax: `dim.id`, `dim.tags`. Index
it like a vector — `dim[i]` returns a single sample (reading only the
block that contains it), `dim[a:b]` returns a range (reading only the
overlapping blocks), and `collect(dim)` (or `dim[:]`) materializes the
entire data series as a typed Julia vector (`Vector{Float64}` for float
columns, `Vector{Vector{UInt8}}` for raw columns).

`dim.id` is **1-based** (1 is typically time, 2 is value for sequential
time-series channels) — the libsie/file underlying convention is
0-based, but Julia code is uniformly 1-based.
"""
struct Dimension
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
    print(io, "Dimension(", _id(d), ")")

# Vector-like access on Dimension:
#
# The methods below let you treat a `Dimension` as a 1-D collection of
# samples without explicitly opening a spigot:
#
#   length(dim)         total sample count
#   eltype(dim)         Float64 or Vector{UInt8} (probed once from libsie)
#   dim[i]              one sample — only the containing block is fetched
#   dim[a:b]            sub-range — only the overlapping blocks are fetched
#   collect(dim)        full materialized vector
#   dim[:]              same as collect(dim)
#   for x in dim ...    iterates the materialized vector
#
# `Dimension` is intentionally not subtyped from `AbstractVector` because the
# element type is data-dependent (float vs raw) and not known at construction
# time. The helpers below cover the common cases without forcing that choice.

# Forward declarations satisfied later in this file:
#   ChannelCache, _channel_cache, _block_for, _locate_row

Base.length(d::Dimension)     = _channel_cache(d.parent.parent::SieFile,
                                                d.parent::Channel).total_rows
Base.size(d::Dimension)       = (length(d),)
Base.firstindex(::Dimension)  = 1
Base.lastindex(d::Dimension)  = length(d)
Base.IteratorSize(::Type{Dimension}) = Base.HasLength()

# eltype probes the first block (cached afterwards). For empty channels we
# default to `Float64` so that downstream `Vector{Float64}` allocations are
# well-defined even when there is nothing to read.
function Base.eltype(d::Dimension)
    ch    = d.parent::Channel
    file  = ch.parent::SieFile
    dimid = _id(d)
    cache = _channel_cache(file, ch)
    haskey(cache.eltype_cache, dimid) && return cache.eltype_cache[dimid]
    cache.nblocks == 0 && return Float64
    _block_for(cache, dimid, 1)   # populates eltype_cache as a side effect
    return cache.eltype_cache[dimid]
end

# Full materialization. Walks the channel via the persistent spigot,
# decoding each block once via the libsie bulk range getters and caching
# the result in the per-channel block LRU. Subsequent index/range/collect
# calls hit the cache and avoid any new ccalls.
Base.collect(d::Dimension)            = _readdim(d)
Base.getindex(d::Dimension, ::Colon)  = _readdim(d)

# Conversion to a concrete Julia vector. `AbstractVector(dim)` and
# `Vector(dim)` are aliases for `collect(dim)` — they materialize every
# block into a typed `Vector{Float64}` or `Vector{Vector{UInt8}}`,
# matching `eltype(dim)`.
(::Type{AbstractVector})(d::Dimension) = _readdim(d)
(::Type{Vector})(d::Dimension)         = _readdim(d)

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
