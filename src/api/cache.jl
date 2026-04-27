# ChannelCache (per-channel decoded-block LRU + persistent spigot):
#
# Vector-like access on a `Dimension` (`length`, `eltype`, `dim[i]`, `dim[a:b]`,
# `collect(dim)`) goes through a per-`Channel` cache:
#
#   - one persistent `Spigot` is opened on first access and reused for every
#     subsequent block fetch (no repeated `sie_spigot_new`/free churn);
#   - a small LRU of decoded blocks keyed by `(block_idx, dim_id)` memoizes
#     the bulk-getter results, so repeated reads near the same row pay no
#     further ccalls;
#   - a precomputed `offsets` vector (cumulative row counts) lets index/range
#     reads jump straight to the containing block via `searchsortedlast`.
#
# All caches for a file are stored in `SieFile.caches` and are freed by
# `_close_caches!` BEFORE `sie_file_close`, since spigots are owned by the
# file. The cache is purely additive — libsie 0.3 is read-only, so blocks
# never need to be invalidated.

const _BLOCK_LRU_DEFAULT = 64

mutable struct ChannelCache
    spigot::Spigot
    offsets::Vector{Int}      # cumulative row counts; len = nblocks + 1
    total_rows::Int
    nblocks::Int
    next_block::Int           # 1-based: index that next!(spigot) will yield
    eltype_cache::Dict{Int, DataType}              # dim_id => Float64 | Vector{UInt8}
    lru::Dict{Tuple{Int,Int}, Any}                 # (block_idx, dim_id) => Vector
    lru_order::Vector{Tuple{Int,Int}}              # oldest first; touch-on-read
    lru_max::Int
end

function ChannelCache(file::SieFile, ch::Channel;
                      lru_max::Integer = _BLOCK_LRU_DEFAULT)
    s = Spigot(file, ch)
    offsets = Int[0]
    nb = 0
    out = next!(s)
    while out !== nothing
        nb += 1
        push!(offsets, offsets[end] + numrows(out))
        out = next!(s)
    end
    reset!(s)
    return ChannelCache(s, offsets, offsets[end], nb, 1,
        Dict{Int, DataType}(),
        Dict{Tuple{Int,Int}, Any}(),
        Tuple{Int,Int}[],
        Int(lru_max))
end

# Advance the persistent spigot until `next!` has yielded block `target`,
# returning that `Output`. The Output is only valid until the next `next!`,
# so callers must decode immediately (see `_decode_block`).
function _advance_to(cache::ChannelCache, target::Int)
    if target < cache.next_block
        reset!(cache.spigot)
        cache.next_block = 1
    end
    out = nothing
    while cache.next_block <= target
        out = next!(cache.spigot)
        out === nothing && error("unexpected end of spigot at block $target")
        cache.next_block += 1
    end
    return out
end

# Decode a whole block for one dimension into a typed Julia vector.
function _decode_block(out::Output, dimid::Int, nr::Int, ct::Symbol)
    d0      = Csize_t(dimid - 1)
    written = Ref{Csize_t}(0)
    if ct === :float64
        buf = Vector{Float64}(undef, nr)
        if nr > 0
            GC.@preserve buf _check(L.sie_output_get_float64_range(
                out.handle, d0, Csize_t(0), Csize_t(nr),
                pointer(buf), written))
        end
        return buf
    elseif ct === :raw
        buf = Vector{Vector{UInt8}}(undef, nr)
        if nr > 0
            ptrs  = Vector{Ptr{UInt8}}(undef, nr)
            sizes = Vector{UInt32}(undef, nr)
            GC.@preserve ptrs sizes _check(L.sie_output_get_raw_range(
                out.handle, d0, Csize_t(0), Csize_t(nr),
                pointer(ptrs), pointer(sizes), written))
            @inbounds for i in 1:nr
                p, n = ptrs[i], Int(sizes[i])
                buf[i] = (p == C_NULL || n == 0) ? UInt8[] :
                    copy(unsafe_wrap(Array, p, n; own = false))
            end
        end
        return buf
    else
        error("dimension $dimid has no data type (:none)")
    end
end

# Touch an existing LRU entry: move the key to the most-recently-used end
# and return the cached vector.
function _touch_lru!(cache::ChannelCache, key::Tuple{Int,Int})
    idx = findfirst(==(key), cache.lru_order)
    idx !== nothing && deleteat!(cache.lru_order, idx)
    push!(cache.lru_order, key)
    return cache.lru[key]
end

# Insert a freshly decoded block, evicting the oldest entries if needed.
function _store_lru!(cache::ChannelCache, key::Tuple{Int,Int}, data)
    cache.lru[key] = data
    push!(cache.lru_order, key)
    while length(cache.lru_order) > cache.lru_max
        old = popfirst!(cache.lru_order)
        delete!(cache.lru, old)
    end
    return data
end

# Locate (block_idx, row_in_block) — both for a 0-based row index that is
# known to be in range. Uses binary search on the small `offsets` vector.
function _locate_row(cache::ChannelCache, target0::Int)
    block_idx = searchsortedlast(cache.offsets, target0)
    return block_idx, target0 - cache.offsets[block_idx]
end

# Fetch decoded data for `(block_idx, dimid)`, decoding via the persistent
# spigot on miss and memoizing in the LRU.
function _block_for(cache::ChannelCache, dimid::Int, block_idx::Int)
    key = (block_idx, dimid)
    haskey(cache.lru, key) && return _touch_lru!(cache, key)
    out = _advance_to(cache, block_idx)
    nr  = numrows(out)
    ct  = coltype(out, dimid)
    if !haskey(cache.eltype_cache, dimid)
        cache.eltype_cache[dimid] =
            ct === :float64 ? Float64           :
            ct === :raw     ? Vector{UInt8}     :
            error("dimension $dimid has no data type (:none)")
    end
    data = _decode_block(out, dimid, nr, ct)
    return _store_lru!(cache, key, data)
end

# Lazily build/lookup the cache for a channel. Refuses on a closed file.
function _channel_cache(sf::SieFile, ch::Channel)
    _check_open(sf)
    h = ch.handle
    cache = get(sf.caches, h, nothing)
    if cache === nothing
        cache = ChannelCache(sf, ch)
        sf.caches[h] = cache
    end
    return cache::ChannelCache
end
