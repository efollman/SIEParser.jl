# Implementation details: per-channel block cache

This document describes how `SomatSIE.jl` accelerates repeated vector-like
access to a `Dimension` (`length(d)`, `eltype(d)`, `d[i]`, `d[a:b]`,
`collect(d)`, `d[:]`) by caching decoded blocks per channel and reusing a
single long-lived `Spigot`.

The cache is **purely an internal optimization**. It does not change any
exported API, return types, or error semantics. Tests written against the
naive (uncached) behavior continue to pass unchanged.

All code referenced below lives in [src/api.jl](src/api.jl).

---

## Why caching?

Without caching, every vector-style method on `Dimension` opened a fresh
`Spigot` (`sie_spigot_new` + `sie_spigot_attach`) and walked the entire
channel block by block. That is fine for one-shot reads, but pathological
for patterns like:

```julia
for i in 1:length(dim)
    use(dim[i])
end
```

which previously was O(n²) in ccalls and freshly decoded every block on
every iteration.

With the cache:

* `length(dim)` is a struct-field read (`cache.total_rows`).
* `dim[i]` does a binary search on a small `Vector` of cumulative row
  counts, then either hits the LRU or decodes one block via a single
  bulk-getter ccall.
* `dim[a:b]` touches only the blocks that overlap the range, each at
  most once.
* `collect(dim)` walks every block exactly once and memoizes them.

libsie 0.3 is read-only, so once a block has been decoded it can never
become stale; the cache never needs invalidation other than on file close.

---

## Where the cache lives

The cache is hung off `SieFile`:

```julia
mutable struct SieFile
    handle::Ptr{Cvoid}
    path::String
    caches::Dict{Ptr{Cvoid}, Any}   # ch.handle -> ChannelCache
end
```

Keys are the libsie channel handles (`ch.handle`), which are stable for the
file's lifetime. The value type is declared as `Any` because `ChannelCache`
is defined later in the same file (after `Spigot`); call sites annotate
`::ChannelCache` where it matters.

`:caches` is *not* a public property — `propertynames(::SieFile)` only
lists it under `private = true`. User code that wants to inspect the
cache must use `getfield(f, :caches)`.

---

## `ChannelCache`

```julia
const _BLOCK_LRU_DEFAULT = 1024

mutable struct ChannelCache
    spigot::Spigot
    offsets::Vector{Int}      # cumulative row counts; length = nblocks + 1
    total_rows::Int
    nblocks::Int
    next_block::Int           # 1-based: index that next!(spigot) will yield
    eltype_cache::Dict{Int, DataType}              # dim_id => Float64 | Vector{UInt8}
    lru::Dict{Tuple{Int,Int}, Any}                 # (block_idx, dim_id) => Vector
    lru_order::Vector{Tuple{Int,Int}}              # oldest first
    lru_max::Int
end
```

### Construction

`ChannelCache(file, ch)` is built lazily on the first vector-like access:

1. Open exactly one `Spigot(file, ch)` and keep it for the lifetime of the
   cache.
2. Walk the spigot once, pushing cumulative row counts into `offsets`.
   This precomputes `total_rows` and `nblocks` so that `length(dim)` and
   `dim[i]` bounds checks are O(1) afterwards.
3. `reset!` the spigot so the next `next!` returns block 1; set
   `next_block = 1`.

This single up-front walk costs one ccall per block (`numrows(out)`) and
nothing more. The spigot is then ready for on-demand block fetches.

### The persistent spigot

`cache.spigot` is reused across **all** subsequent block fetches for that
channel. `_advance_to(cache, target)` advances it forward via `next!`
until it has yielded the requested 1-based block index. If the caller asks
for an earlier block than `next_block`, it `reset!`s and replays from the
start. `next_block` is bumped after every `next!` so the next call knows
where the spigot is positioned.

This eliminates the per-call `sie_spigot_new` / `sie_spigot_free` churn
that the previous implementation incurred for every `dim[i]`.

### The block LRU

Hits are keyed on `(block_idx, dim_id)`. Values are typed Julia vectors,
**not** libsie `Output` objects — `Output` handles are invalidated by the
next `next!`, so caching them would be unsafe. Instead, every cache miss
calls `_decode_block` immediately, which does one bulk-getter ccall
(`sie_output_get_float64_range` or `sie_output_get_raw_range`) into a
freshly allocated `Vector{Float64}` or `Vector{Vector{UInt8}}`.

Eviction is true-LRU and capped at `_BLOCK_LRU_DEFAULT = 1024` entries:

* `_touch_lru!(cache, key)` — on hit, removes the key from `lru_order`
  and re-pushes it to the end (most-recently-used).
* `_store_lru!(cache, key, data)` — on miss, inserts the entry at the
  end and pops the oldest until `length(lru_order) <= lru_max`.

64 was chosen as a reasonable default: large enough to swallow typical
neighborhood/iteration patterns, small enough to bound memory even for
multi-million-row files. The cap is a `const`, not a kwarg, by design —
exposing a knob would lock in API surface for an internal optimization.

### Row → block lookup

`_locate_row(cache, target0)` translates a 0-based row index into
`(block_idx, row_in_block)` via `searchsortedlast(cache.offsets, target0)`.
Because `offsets` is small (one entry per block) and sorted, this is
O(log nblocks) and allocation-free.

### `eltype_cache`

`Base.eltype(dim)` is called all over the place by Julia's iteration and
broadcasting machinery, so it is memoized per `dim_id`. The first probe
either reads a cached value or forces a decode of block 1 (which writes
the eltype as a side effect inside `_block_for`). For empty channels we
short-circuit to `Float64` so downstream `Vector{Float64}(undef, 0)`
allocations are well-defined.

---

## Lifecycle

The libsie ownership rule is: spigots are owned by the file. They must be
freed **before** `sie_file_close`. Both file-close paths honor this:

```julia
function _finalize_file(sf::SieFile)
    if sf.handle != C_NULL
        _close_caches!(sf)
        L.sie_file_close(sf.handle)
        sf.handle = C_NULL
    end
end

function Base.close(sf::SieFile)
    if sf.handle != C_NULL
        _close_caches!(sf)
        L.sie_file_close(sf.handle)
        sf.handle = C_NULL
    end
    return nothing
end
```

`_close_caches!` iterates every `ChannelCache`, closes its `Spigot` in a
`try/catch` (so one bad spigot can't block cleanup), and `empty!`s the
dict. Closing the underlying file via `Base.close` therefore also drops
the entire cache; further dimension reads on the (now-closed) file go
through `_check_open` in `_channel_cache` and raise a `SieError`.

---

## How the `Dimension` methods use the cache

```julia
Base.length(d)      = _channel_cache(d.parent.parent, d.parent).total_rows

Base.eltype(d)      = consult cache.eltype_cache, else _block_for(cache, dimid, 1)

d[i::Integer]       = block_idx, row = _locate_row(cache, i - 1)
                      _block_for(cache, dimid, block_idx)[row + 1]

d[r::UnitRange]     = blo, _ = _locate_row(cache, first(r) - 1)
                      bhi, _ = _locate_row(cache, last(r) - 1)
                      for b in blo:bhi: copy overlap of _block_for(...)

collect(d), d[:]    = _readdim(d) walks 1:cache.nblocks via _block_for
```

The range path computes only the overlap with each touched block, so
`dim[a:b]` never copies more than `b - a + 1` samples.

`numrows(file::SieFile, ch::Channel)` is now a one-liner that returns
`_channel_cache(file, ch).total_rows`.

---

## Cost model

Let `B` be the number of blocks in a channel and `K` the LRU capacity
(64).

| Operation                          | First call (cold) | Repeated call (hot) |
|------------------------------------|-------------------|---------------------|
| `length(dim)`                      | one full walk     | O(1) field read     |
| `eltype(dim)`                      | decode block 1    | O(1) dict lookup    |
| `dim[i]` (block in LRU)            | one block decode  | O(log B) + O(K)     |
| `dim[i]` (block evicted)           | n/a               | one block decode    |
| `dim[a:b]` over `m` blocks         | `m` block decodes | up to `m` LRU hits  |
| `collect(dim)` / `dim[:]`          | `B` block decodes | `B` LRU hits        |

The `O(K)` term in the hit case comes from the linear scan in
`_touch_lru!` (`findfirst` over `lru_order`). With `K = 64` this is
negligible compared to a single ccall, and it keeps the data structures
simple — no doubly-linked list bookkeeping needed.

---

## Memory bound

A single `ChannelCache` holds at most `K = 64` decoded blocks. For a
typical timehistory channel that's a few MB; for a raw/CAN channel
storing `Vector{UInt8}` per row it scales with the per-frame payload.
The cache is per channel, so total memory is roughly
`(touched channels) × K × (block size)`. On `close(f)` (or GC of the
`SieFile`) everything is released and the underlying spigots are freed
back to libsie.

---

## What is *not* cached

* Channel/test/dimension *metadata* (names, units, tags, etc.) is fetched
  on demand from libsie and not memoized — these calls are already cheap
  and the metadata isn't accessed in tight loops.
* `Output` handles. They are invalidated by the next `next!` and so are
  never stored anywhere; only their decoded contents are.
