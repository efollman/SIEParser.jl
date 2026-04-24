# High-level Julia API for libsie.
#
# Provides Julia-idiomatic types backed by libsie's opaque handles plus
# `open`/`close`, iteration, indexing, and `read` semantics that should feel
# natural to Julia users.

using .LibSIE
const L = LibSIE

# ── Errors ──────────────────────────────────────────────────────────────────

"""
    SieError(code, message)

Exception thrown when a libsie call returns a non-zero status code.
"""
struct SieError <: Exception
    code::Int
    message::String
end

Base.showerror(io::IO, e::SieError) =
    print(io, "SieError(", e.code, "): ", e.message)

@inline function _check(rc::Integer)
    rc == L.SIE_OK && return nothing
    throw(SieError(Int(rc), L.sie_status_message(rc)))
end

# ── Helpers for (ptr, len) string returns ───────────────────────────────────────────

function _ptrlen_to_string(getter, h)
    pref = Ref{Ptr{UInt8}}(C_NULL)
    nref = Ref{Csize_t}(0)
    getter(h, pref, nref)
    p, n = pref[], Int(nref[])
    (p == C_NULL || n == 0) ? "" : unsafe_string(p, n)
end

function _ptrlen_to_bytes(getter, h)
    pref = Ref{Ptr{UInt8}}(C_NULL)
    nref = Ref{Csize_t}(0)
    getter(h, pref, nref)
    p, n = pref[], Int(nref[])
    (p == C_NULL || n == 0) ? UInt8[] : copy(unsafe_wrap(Array, p, n; own = false))
end


# ── Tags ────────────────────────────────────────────────────────────────────

"""
    Tags

Type alias for `Dict{String, Union{String, Vector{UInt8}}}` — the result of
calling [`tags`](@ref) on a [`SieFile`](@ref), [`Test`](@ref),
[`Channel`](@ref), or [`Dimension`](@ref).

Each entry maps a tag key to its value. Textual tags map to `String`; binary
blob tags (rare; e.g. arbitrary payloads) map to `Vector{UInt8}`. Use the
normal `Dict` API: `length`, iteration, `tags[k]`, `get(tags, k, default)`,
`haskey(tags, k)`, `keys(tags)`, `values(tags)`.

```julia
ts = tags(ch)
sr = get(ts, "core:sample_rate", nothing)
```
"""
const Tags = Dict{String, Union{String, Vector{UInt8}}}

# Internal: build a Tags dict from a libsie parent handle.
#
#   parent_handle  - opaque parent handle (file/test/channel/dimension)
#   count          - number of tags
#   getter         - (parent_handle, i0::Csize_t) -> tag handle
function _build_tags(parent_handle::Ptr{Cvoid}, count::Integer, getter)
    out = Tags()
    sizehint!(out, count)
    for i in 0:(count - 1)
        h = getter(parent_handle, i)
        h == C_NULL && continue
        k = _ptrlen_to_string(L.sie_tag_key, h)
        v = L.sie_tag_is_string(h) != 0 ?
            _ptrlen_to_string(L.sie_tag_value, h) :
            _ptrlen_to_bytes(L.sie_tag_value, h)
        out[k] = v
    end
    return out
end

# ── Dimension ───────────────────────────────────────────────────────────────

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

# ── Vector-like access on Dimension ─────────────────────────────────────────
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

# ── Channel ─────────────────────────────────────────────────────────────────

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

# ── Test ────────────────────────────────────────────────────────────────────

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

# ── SieFile ─────────────────────────────────────────────────────────────────

"""
    SieFile

An opened SIE file handle. Open one with [`opensie`](@ref) using the
do-block form so the underlying libsie handle is released automatically:

    opensie("myfile.sie") do f
        for t in f.tests, ch in t.channels
            for dim in ch.dims
                println(ch.name, " dim ", dim.id, ": ", collect(dim))
            end
        end
    end
"""
mutable struct SieFile
    handle::Ptr{Cvoid}
    path::String
    # Per-channel cache of decoded blocks + a persistent spigot. Populated
    # lazily on first vector-like access of a `Dimension`. Keyed by the
    # libsie channel handle (stable for the file's lifetime). Type-erased
    # to `Any` because `ChannelCache` is defined further down in this file.
    caches::Dict{Ptr{Cvoid}, Any}

    function SieFile(path::AbstractString)
        out = Ref{Ptr{Cvoid}}(C_NULL)
        _check(L.sie_file_open(String(path), out))
        sf = new(out[], String(path), Dict{Ptr{Cvoid}, Any}())
        finalizer(_finalize_file, sf)
        return sf
    end
end

handle(sf::SieFile) = sf.handle

# Close every cached spigot for `sf` and forget them. Must run BEFORE the
# underlying file handle is freed, because spigots are owned by the file.
function _close_caches!(sf::SieFile)
    isempty(sf.caches) && return nothing
    for (_, cache) in sf.caches
        try
            close(cache.spigot)
        catch
            # Best-effort: don't let a single bad spigot block cleanup.
        end
    end
    empty!(sf.caches)
    return nothing
end

function _finalize_file(sf::SieFile)
    if sf.handle != C_NULL
        _close_caches!(sf)
        L.sie_file_close(sf.handle)
        sf.handle = C_NULL
    end
end

"""
    close(file::SieFile)

Release the underlying libsie file handle. Idempotent. After closing, any
borrowed `Test`/`Channel`/`Tag`/`Dimension` references become invalid.
"""
function Base.close(sf::SieFile)
    if sf.handle != C_NULL
        _close_caches!(sf)
        L.sie_file_close(sf.handle)
        sf.handle = C_NULL
    end
    return nothing
end

Base.isopen(sf::SieFile) = sf.handle != C_NULL

"""
    opensie(f::Function, path)

Open the SIE file at `path`, pass the resulting [`SieFile`](@ref) to `f`,
and close it (releasing the underlying libsie handle) when `f` returns
\u2014 even if it throws. Use it with do-block syntax:

```julia
opensie("myfile.sie") do f
    for t in f.tests, ch in t.channels
        println(ch.name)
    end
end
```
"""
opensie(path::AbstractString) = SieFile(path)

function opensie(f::Function, path::AbstractString)
    sf = SieFile(path)
    try
        return f(sf)
    finally
        close(sf)
    end
end

function _check_open(sf::SieFile)
    sf.handle == C_NULL && error("SieFile is closed")
    return sf.handle
end

_ntests(sf::SieFile) = Int(L.sie_file_num_tests(_check_open(sf)))

function _test(sf::SieFile, i::Integer)
    h = _check_open(sf)
    1 <= i <= _ntests(sf) || throw(BoundsError(sf, i))
    p = L.sie_file_test(h, i - 1)
    p == C_NULL ? throw(BoundsError(sf, i)) : Test(p, sf)
end

_tests(sf::SieFile) = [_test(sf, i) for i in 1:_ntests(sf)]

_tags(sf::SieFile) = (h = _check_open(sf);
    _build_tags(h, Int(L.sie_file_num_tags(h)), L.sie_file_tag))

"""
    findchannel(test, name::AbstractString) -> Channel | nothing

Look up a channel within `test` by its name. Returns `nothing` if no
channel in the test has the requested name. The match is exact
(case-sensitive); if multiple channels share the name, the first one is
returned.
"""
function findchannel(t::Test, chname::AbstractString)
    for c in t.channels
        c.name == chname && return c
    end
    return nothing
end

function Base.getproperty(sf::SieFile, sym::Symbol)
    sym === :tests && return _tests(sf)
    sym === :tags  && return _tags(sf)
    sym === :channels && error(
        "`SieFile` has no `channels` property because channel ids may " *
        "collide between tests. Iterate via `f.tests` instead, e.g. " *
        "[ch for t in f.tests for ch in t.channels].")
    return getfield(sf, sym)
end
Base.propertynames(::SieFile, private::Bool = false) =
    private ? (:tests, :tags, :path, :handle, :caches) : (:tests, :tags, :path)

Base.show(io::IO, sf::SieFile) = print(io,
    "SieFile(", repr(sf.path), isopen(sf) ? "" : ", closed", ")")

# ── Output ──────────────────────────────────────────────────────────────────

"""
    Output

A single decoded data block produced by a [`Spigot`](@ref). Owned by the
spigot — invalidated by the next `read`/`iterate` on that spigot.

Use [`numrows`](@ref), [`numdims`](@ref), [`block`](@ref), [`coltype`](@ref),
[`getfloat64`](@ref), [`getraw`](@ref), or [`Matrix`](@ref) for a copy of all
float64 columns.
"""
struct Output
    handle::Ptr{Cvoid}
    parent::Any  # keeps Spigot alive (and thus the data buffer)
end

handle(o::Output) = o.handle

numdims(o::Output) = Int(L.sie_output_num_dims(o.handle))
numrows(o::Output) = Int(L.sie_output_num_rows(o.handle))
block(o::Output)   = Int(L.sie_output_block(o.handle))

"""
    coltype(out::Output, dim::Integer) -> Symbol

`:float64`, `:raw`, or `:none` for the given 1-based dimension.
"""
function coltype(o::Output, dim::Integer)
    1 <= dim <= numdims(o) || throw(BoundsError(o, dim))
    t = L.sie_output_type(o.handle, dim - 1)
    t == L.SIE_OUTPUT_FLOAT64 ? :float64 :
    t == L.SIE_OUTPUT_RAW     ? :raw     :
                                :none
end

"""
    getfloat64(out, dim, row) -> Float64

Read the float64 sample at the 1-based `(dim, row)`. Throws if the column is
not a float64 column.
"""
function getfloat64(o::Output, dim::Integer, row::Integer)
    r = Ref{Cdouble}(0.0)
    _check(L.sie_output_get_float64(o.handle, dim - 1, row - 1, r))
    return r[]
end

"""
    getraw(out, dim, row) -> Vector{UInt8}

Copy of the raw binary sample at 1-based `(dim, row)`. Throws if the column
is not a raw column.
"""
function getraw(o::Output, dim::Integer, row::Integer)
    pref = Ref{Ptr{UInt8}}(C_NULL)
    sref = Ref{UInt32}(0)
    _check(L.sie_output_get_raw(o.handle, dim - 1, row - 1, pref, sref))
    p, n = pref[], Int(sref[])
    (p == C_NULL || n == 0) ? UInt8[] : copy(unsafe_wrap(Array, p, n; own = false))
end

"""
    Matrix(out::Output) -> Matrix{Float64}

Convert all float64 columns to a `(numrows, numdims)` matrix. **Throws** if
any column is a raw column — for mixed-type outputs (e.g. CAN channels with
a raw frame dimension), iterate the spigot and use [`getfloat64`](@ref) /
[`getraw`](@ref) per dimension instead.
"""
function Base.Matrix(o::Output)
    nr, nd = numrows(o), numdims(o)
    for d in 1:nd
        coltype(o, d) === :float64 ||
            throw(ArgumentError(
                "dimension $d is :$(coltype(o, d)); cannot convert mixed/raw " *
                "Output to Matrix{Float64} — read per-dimension instead"))
    end
    M = Matrix{Float64}(undef, nr, nd)
    nr == 0 && return M
    written = Ref{Csize_t}(0)
    GC.@preserve M begin
        for d in 1:nd
            base = pointer(M, (d - 1) * nr + 1)
            _check(L.sie_output_get_float64_range(
                o.handle, Csize_t(d - 1), Csize_t(0), Csize_t(nr), base, written))
        end
    end
    return M
end

Base.size(o::Output) = (numrows(o), numdims(o))
Base.show(io::IO, o::Output) = print(io,
    "Output(block=", block(o), ", rows=", numrows(o), ", dims=", numdims(o), ")")

# ── Spigot ──────────────────────────────────────────────────────────────────

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
    channel::Channel

    function Spigot(file::SieFile, ch::Channel)
        out = Ref{Ptr{Cvoid}}(C_NULL)
        _check(L.sie_spigot_attach(_check_open(file), ch.handle, out))
        s = new(out[], file, ch)
        finalizer(_finalize_spigot, s)
        return s
    end
end

handle(s::Spigot) = s.handle

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
spigot(file::SieFile, ch::Channel) = Spigot(file, ch)

function spigot(f::Function, file::SieFile, ch::Channel)
    s = Spigot(file, ch)
    try
        return f(s)
    finally
        close(s)
    end
end

numblocks(s::Spigot)         = Int(L.sie_spigot_num_blocks(s.handle))
isdone(s::Spigot)            = L.sie_spigot_is_done(s.handle) != 0
Base.position(s::Spigot)     = Int(L.sie_spigot_tell(s.handle))
Base.seek(s::Spigot, target) = (L.sie_spigot_seek(s.handle, UInt64(target)); s)
reset!(s::Spigot)            = (L.sie_spigot_reset(s.handle); s)
disable_transforms!(s::Spigot, disable::Bool = true) =
    (L.sie_spigot_disable_transforms(s.handle, disable ? 1 : 0); s)
set_scan_limit!(s::Spigot, limit::Integer) =
    (L.sie_spigot_set_scan_limit(s.handle, limit); s)

"""
    next!(s::Spigot) -> Output | nothing

Pull the next data block. Returns `nothing` at end-of-stream.
"""
function next!(s::Spigot)
    s.handle == C_NULL && error("Spigot is closed")
    out = Ref{Ptr{Cvoid}}(C_NULL)
    _check(L.sie_spigot_get(s.handle, out))
    p = out[]
    p == C_NULL ? nothing : Output(p, s)
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
function _readdim(d::Dimension)
    ch    = d.parent::Channel
    file  = ch.parent::SieFile
    cache = _channel_cache(file, ch)
    cache.total_rows == 0 && return Float64[]
    et    = eltype(d)
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
numrows(file::SieFile, ch::Channel) = _channel_cache(file, ch).total_rows

Base.show(io::IO, s::Spigot) = print(io,
    "Spigot(channel=", _id(s.channel), isopen(s) ? "" : ", closed", ")")

# ── ChannelCache (per-channel decoded-block LRU + persistent spigot) ────────
#
# Vector-like access on a `Dimension` (`length`, `eltype`, `dim[i]`, `dim[a:b]`,
# `collect(dim)`) goes through a per-`Channel` cache:
#
#   * one persistent `Spigot` is opened on first access and reused for every
#     subsequent block fetch (no repeated `sie_spigot_new`/free churn);
#   * a small LRU of decoded blocks keyed by `(block_idx, dim_id)` memoizes
#     the bulk-getter results, so repeated reads near the same row pay no
#     further ccalls;
#   * a precomputed `offsets` vector (cumulative row counts) lets index/range
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

# ── Stream (incremental ingest) ─────────────────────────────────────────────

"""
    Stream()

Incremental SIE block parser. Feed bytes with [`add!`](@ref) and inspect
group state via [`numgroups`](@ref) and friends. Useful when the SIE data
arrives over a network or is being produced in real time.
"""
mutable struct Stream
    handle::Ptr{Cvoid}

    function Stream()
        out = Ref{Ptr{Cvoid}}(C_NULL)
        _check(L.sie_stream_new(out))
        s = new(out[])
        finalizer(_finalize_stream, s)
        return s
    end
end

handle(s::Stream) = s.handle

function _finalize_stream(s::Stream)
    if s.handle != C_NULL
        L.sie_stream_free(s.handle)
        s.handle = C_NULL
    end
end

function Base.close(s::Stream)
    if s.handle != C_NULL
        L.sie_stream_free(s.handle)
        s.handle = C_NULL
    end
    return nothing
end

"""
    add!(stream, bytes::AbstractVector{UInt8}) -> Int

Feed `bytes` into the stream. Returns the number of bytes consumed. Bytes
not consumed should be re-presented in the next call together with new
data.
"""
function add!(s::Stream, bytes::AbstractVector{UInt8})
    s.handle == C_NULL && error("Stream is closed")
    consumed = Ref{Csize_t}(0)
    GC.@preserve bytes _check(L.sie_stream_add_data(
        s.handle, pointer(bytes), length(bytes), consumed))
    return Int(consumed[])
end

numgroups(s::Stream)              = Int(L.sie_stream_num_groups(s.handle))
group_numblocks(s::Stream, gid)   = Int(L.sie_stream_group_num_blocks(s.handle, gid))
group_numbytes(s::Stream, gid)    = Int(L.sie_stream_group_num_bytes(s.handle, gid))
group_isclosed(s::Stream, gid)    = L.sie_stream_is_group_closed(s.handle, gid) != 0

Base.show(io::IO, s::Stream) =
    print(io, "Stream(groups=", s.handle == C_NULL ? "<closed>" : numgroups(s), ")")

# ── Histogram ───────────────────────────────────────────────────────────────

"""
    Histogram(file, channel)

Build an in-memory histogram view of a histogram-typed channel. Use
[`numdims`](@ref), [`numbins`](@ref), [`getbin`](@ref), [`bounds`](@ref).
"""
mutable struct Histogram
    handle::Ptr{Cvoid}
    file::SieFile
    channel::Channel

    function Histogram(file::SieFile, ch::Channel)
        out = Ref{Ptr{Cvoid}}(C_NULL)
        _check(L.sie_histogram_from_channel(_check_open(file), ch.handle, out))
        h = new(out[], file, ch)
        finalizer(_finalize_histogram, h)
        return h
    end
end

handle(h::Histogram) = h.handle

function _finalize_histogram(h::Histogram)
    if h.handle != C_NULL
        L.sie_histogram_free(h.handle)
        h.handle = C_NULL
    end
end

function Base.close(h::Histogram)
    if h.handle != C_NULL
        L.sie_histogram_free(h.handle)
        h.handle = C_NULL
    end
    return nothing
end

numdims(h::Histogram)   = Int(L.sie_histogram_num_dims(h.handle))
totalsize(h::Histogram) = Int(L.sie_histogram_total_size(h.handle))
numbins(h::Histogram, dim::Integer) = Int(L.sie_histogram_num_bins(h.handle, dim - 1))

"""
    getbin(h::Histogram, indices) -> Float64

`indices` is a tuple/vector of 1-based bin indices, one per dimension.
"""
function getbin(h::Histogram, indices)
    nd = numdims(h)
    length(indices) == nd ||
        throw(ArgumentError("expected $nd indices, got $(length(indices))"))
    idx0 = Csize_t[Csize_t(i - 1) for i in indices]
    val  = Ref{Cdouble}(0.0)
    GC.@preserve idx0 _check(L.sie_histogram_get_bin(h.handle, pointer(idx0), val))
    return val[]
end

"""
    bounds(h::Histogram, dim::Integer) -> (lower::Vector{Float64}, upper::Vector{Float64})

Lower and upper bin bounds for a dimension.
"""
function bounds(h::Histogram, dim::Integer)
    nb = numbins(h, dim)
    lo = Vector{Cdouble}(undef, nb)
    hi = Vector{Cdouble}(undef, nb)
    _check(L.sie_histogram_get_bounds(h.handle, dim - 1, lo, hi, nb))
    return lo, hi
end

Base.show(io::IO, h::Histogram) = print(io,
    "Histogram(channel=", id(h.channel), ", dims=",
    h.handle == C_NULL ? "<closed>" : numdims(h), ")")
