# Spigot:
"""
    Spigot(file, channel)
    spigot(file, channel)

Create a data spigot reading `channel` from `file`. Iterate to obtain
[`Output`](@ref) blocks, or call [`read`](@ref) to materialize the whole
channel.

Always close with [`close`](@ref) or use the do-block form via
`spigot(file, channel) do s ... end`.
"""
mutable struct Spigot
    handle::Ptr{Cvoid}
    file::SieFile
    channel::LibSieChannel
    # Bumped on every `next!` and `reset!`. Each `Output` snapshots the
    # value at the moment it was produced; subsequent accessors verify
    # the spigot is still on the same generation, so use-after-invalidate
    # raises a clear error instead of reading freed C memory.
    gen::UInt64

    function Spigot(file::SieFile, ch::LibSieChannel)
        out = Ref{Ptr{Cvoid}}(C_NULL)
        _check(L.sie_spigot_attach(_check_open(file), ch.handle, out))
        s = new(out[], file, ch, UInt64(0))
        finalizer(_finalize_spigot, s)
        return s
    end
end

function _finalize_spigot(s::Spigot)
    if s.handle != C_NULL
        L.sie_spigot_free(s.handle)
        s.handle = C_NULL
    end
end

function Base.close(s::Spigot)
    if s.handle != C_NULL
        L.sie_spigot_free(s.handle)
        s.handle = C_NULL
    end
    return nothing
end

Base.isopen(s::Spigot) = s.handle != C_NULL

"""
    spigot(file, channel) -> Spigot
    spigot(f, file, channel)
"""
spigot(file::SieFile, ch::LibSieChannel) = Spigot(file, ch)

function spigot(f::Function, file::SieFile, ch::LibSieChannel)
    s = Spigot(file, ch)
    try
        return f(s)
    finally
        close(s)
    end
end

numblocks(s::Spigot)     = Int(L.sie_spigot_num_blocks(s.handle))
Base.position(s::Spigot) = Int(L.sie_spigot_tell(s.handle))
reset!(s::Spigot)        = (L.sie_spigot_reset(s.handle); s.gen += UInt64(1); s)

"""
    next!(s::Spigot) -> Output | nothing

Pull the next data block. Returns `nothing` at end-of-stream.
"""
function next!(s::Spigot)
    s.handle == C_NULL && error("Spigot is closed")
    out = Ref{Ptr{Cvoid}}(C_NULL)
    _check(L.sie_spigot_get(s.handle, out))
    p = out[]
    s.gen += UInt64(1)
    p == C_NULL ? nothing : Output(p, s, s.gen)
end

# Iteration: yields Output objects (each invalidated when the next is fetched)
Base.IteratorSize(::Type{Spigot}) = Base.SizeUnknown()
Base.eltype(::Type{Spigot}) = Output

function Base.iterate(s::Spigot, _state = nothing)
    out = next!(s)
    out === nothing ? nothing : (out, nothing)
end

"""
    _readdim(dim::Dimension) -> Vector{Float64} | Vector{Vector{UInt8}}

Internal: read the entire data series for a single dimension into a
Julia vector. Backs `collect(dim)` and `dim[:]`.

The element type is chosen from the dimension's column type:

* `:float64` columns return a `Vector{Float64}` of engineering-scaled samples.
* `:raw`     columns return a `Vector{Vector{UInt8}}`, one byte string per
  sample (e.g. CAN frames).

Walks the channel's spigot once and pulls each block via the libsie bulk
getters (`sie_output_get_float64_range` / `sie_output_get_raw_range`), so
each block costs a single `ccall` instead of one per sample.
"""
function _readdim(d::LibSieDimension)
    ch    = d.parent::LibSieChannel
    file  = ch.parent::SieFile
    cache = _channel_cache(file, ch)
    et    = eltype(d)
    cache.total_rows == 0 &&
        return et === Float64 ? Float64[] : Vector{UInt8}[]
    dimid = _id(d)
    result = et === Float64 ? Vector{Float64}(undef, cache.total_rows) :
                              Vector{Vector{UInt8}}(undef, cache.total_rows)
    pos = 1
    @inbounds for b in 1:cache.nblocks
        block = _block_for(cache, dimid, b)
        n = length(block)
        for k in 1:n
            result[pos + k - 1] = block[k]
        end
        pos += n
    end
    return result
end

"""
    numrows(file::SieFile, ch::Channel) -> Int

Total number of samples in `ch` without materializing the data. Walks the
channel's spigot once, summing `numrows(out)` per block — one ccall per
block rather than per sample, so cheap even for multi-million-row channels.

Useful when constructing a time axis for a sequential time-history channel
directly from `core:sample_rate` instead of reading dim-0.
"""
numrows(file::SieFile, ch::LibSieChannel) = _channel_cache(file, ch).total_rows

Base.show(io::IO, s::Spigot) = print(io,
    "Spigot(channel=", _id(s.channel), isopen(s) ? "" : ", closed", ")")
