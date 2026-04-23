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

# ── Helpers for (ptr, len) string returns ───────────────────────────────────

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

# ── Library info ────────────────────────────────────────────────────────────

"""
    libsie_version() -> String

Return the version string of the underlying libsie shared library.
"""
libsie_version() = L.sie_version()

# ── Tag ─────────────────────────────────────────────────────────────────────

"""
    Tag

A key/value metadata entry attached to a [`SieFile`](@ref), [`Test`](@ref),
[`Channel`](@ref) or [`Dimension`](@ref). Values may be strings or arbitrary
binary blobs (use [`isbinary`](@ref) / [`isstring`](@ref) to distinguish).

Borrowed from its parent — does not need explicit cleanup.
"""
struct Tag
    handle::Ptr{Cvoid}
end

handle(t::Tag) = t.handle

key(t::Tag)         = _ptrlen_to_string(L.sie_tag_key, t.handle)
isstring(t::Tag)    = L.sie_tag_is_string(t.handle) != 0
isbinary(t::Tag)    = L.sie_tag_is_binary(t.handle) != 0
valuesize(t::Tag)   = Int(L.sie_tag_value_size(t.handle))

"""
    value(t::Tag) -> Union{String, Vector{UInt8}}

Return the tag value as a `String` if the tag is textual, otherwise as a
`Vector{UInt8}` copy of the binary payload.
"""
function value(t::Tag)
    isstring(t) ? _ptrlen_to_string(L.sie_tag_value, t.handle) :
                  _ptrlen_to_bytes(L.sie_tag_value, t.handle)
end

group(t::Tag) = Int(L.sie_tag_group(t.handle))
isfromgroup(t::Tag) = L.sie_tag_is_from_group(t.handle) != 0

Base.show(io::IO, t::Tag) = print(io, "Tag(", repr(key(t)), " => ",
    isstring(t) ? repr(value(t)) : string("<binary ", valuesize(t), " bytes>"), ")")

# ── Tag collections (lazy, dict-like) ───────────────────────────────────────

"""
    Tags(parent, count, getter, finder)

Iterable, indexable, dict-like view of the tag list owned by `parent`.

* `length(tags)`, iteration  — sequential access
* `tags[i]`                  — 1-based positional access (returns `Tag`)
* `tags[key::AbstractString]` — keyed access (returns `Tag`, throws `KeyError`)
* `get(tags, key, default)`  — keyed access with default
* `haskey(tags, key)`        — membership test
"""
struct Tags
    parent::Any              # keeps owning object alive
    count::Int
    getter::Function         # (parent_handle, i0) -> tag handle
    finder::Union{Function,Nothing}  # (parent_handle, key) -> tag handle or nothing
end

Base.length(t::Tags) = t.count
Base.size(t::Tags) = (t.count,)
Base.eltype(::Type{Tags}) = Tag
Base.firstindex(::Tags) = 1
Base.lastindex(t::Tags) = t.count

function Base.getindex(t::Tags, i::Integer)
    1 <= i <= t.count || throw(BoundsError(t, i))
    h = t.getter(handle(t.parent), i - 1)
    h == C_NULL ? throw(BoundsError(t, i)) : Tag(h)
end

function Base.getindex(t::Tags, k::AbstractString)
    tag = _findtag(t, k)
    tag === nothing ? throw(KeyError(k)) : tag
end

function _findtag(t::Tags, k::AbstractString)
    t.finder === nothing && return _linearfind(t, k)
    h = t.finder(handle(t.parent), k)
    h == C_NULL ? nothing : Tag(h)
end

function _linearfind(t::Tags, k::AbstractString)
    for i in 1:t.count
        tag = t[i]
        key(tag) == k && return tag
    end
    return nothing
end

Base.get(t::Tags, k::AbstractString, default) =
    (tag = _findtag(t, k); tag === nothing ? default : tag)

Base.haskey(t::Tags, k::AbstractString) = _findtag(t, k) !== nothing

Base.iterate(t::Tags, i::Int = 1) = i > t.count ? nothing : (t[i], i + 1)

function Base.show(io::IO, t::Tags)
    print(io, "Tags(", t.count, ")")
end

# ── Dimension ───────────────────────────────────────────────────────────────

"""
    Dimension

A single axis ("column") of a [`Channel`](@ref). Borrowed from the channel.

Use [`index`](@ref) and [`name`](@ref) for identity, [`tags`](@ref) for
per-dimension metadata, and `read(file, dim)` to materialize the dimension's
entire data series as a typed Julia vector — see
[`read(::SieFile, ::Dimension)`](@ref).
"""
struct Dimension
    handle::Ptr{Cvoid}
    parent::Any  # Channel — typed Any to avoid forward declaration; see ch field below
end

handle(d::Dimension) = d.handle

"""
    index(dim::Dimension) -> Int

Zero-based dimension index (0 is typically time, 1 is value for sequential
time-series channels).
"""
index(d::Dimension) = Int(L.sie_dimension_index(d.handle))
name(d::Dimension)  = _ptrlen_to_string(L.sie_dimension_name, d.handle)

tags(d::Dimension) = Tags(d, Int(L.sie_dimension_num_tags(d.handle)),
    L.sie_dimension_tag, L.sie_dimension_find_tag)

Base.show(io::IO, d::Dimension) =
    print(io, "Dimension(", index(d), ", ", repr(name(d)), ")")

# ── Channel ─────────────────────────────────────────────────────────────────

"""
    Channel

A data series within a [`SieFile`](@ref). Borrowed from the file.
"""
struct Channel
    handle::Ptr{Cvoid}
    parent::Any   # keeps SieFile alive
end

handle(c::Channel) = c.handle

id(c::Channel)      = Int(L.sie_channel_id(c.handle))
testid(c::Channel)  = Int(L.sie_channel_test_id(c.handle))
name(c::Channel)    = _ptrlen_to_string(L.sie_channel_name, c.handle)
numdims(c::Channel) = Int(L.sie_channel_num_dims(c.handle))

function dimension(c::Channel, i::Integer)
    1 <= i <= numdims(c) || throw(BoundsError(c, i))
    h = L.sie_channel_dimension(c.handle, i - 1)
    h == C_NULL ? throw(BoundsError(c, i)) : Dimension(h, c)
end

dimensions(c::Channel) = [dimension(c, i) for i in 1:numdims(c)]

tags(c::Channel) = Tags(c, Int(L.sie_channel_num_tags(c.handle)),
    L.sie_channel_tag, L.sie_channel_find_tag)

Base.show(io::IO, c::Channel) =
    print(io, "Channel(id=", id(c), ", name=", repr(name(c)),
              ", ndims=", numdims(c), ")")

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

handle(t::Test) = t.handle

id(t::Test)   = Int(L.sie_test_id(t.handle))
name(t::Test) = _ptrlen_to_string(L.sie_test_name, t.handle)
nchannels(t::Test) = Int(L.sie_test_num_channels(t.handle))

function channel(t::Test, i::Integer)
    1 <= i <= nchannels(t) || throw(BoundsError(t, i))
    h = L.sie_test_channel(t.handle, i - 1)
    h == C_NULL ? throw(BoundsError(t, i)) : Channel(h, t.parent)
end

channels(t::Test) = [channel(t, i) for i in 1:nchannels(t)]

tags(t::Test) = Tags(t, Int(L.sie_test_num_tags(t.handle)),
    L.sie_test_tag, L.sie_test_find_tag)

Base.show(io::IO, t::Test) =
    print(io, "Test(id=", id(t), ", name=", repr(name(t)),
              ", nchannels=", nchannels(t), ")")

# ── SieFile ─────────────────────────────────────────────────────────────────

"""
    SieFile(path)
    open(SieFile, path)
    open(f, SieFile, path)

Open a SIE file by path. The handle is closed via [`close`](@ref) (also via a
finalizer if it is forgotten). The do-block form is the recommended pattern:

    open(SomatSIE.SieFile, "myfile.sie") do f
        for ch in channels(f)
            println(name(ch), ": ", read(f, ch))
        end
    end
"""
mutable struct SieFile
    handle::Ptr{Cvoid}
    path::String

    function SieFile(path::AbstractString)
        out = Ref{Ptr{Cvoid}}(C_NULL)
        _check(L.sie_file_open(String(path), out))
        sf = new(out[], String(path))
        finalizer(_finalize_file, sf)
        return sf
    end
end

handle(sf::SieFile) = sf.handle

function _finalize_file(sf::SieFile)
    if sf.handle != C_NULL
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
        L.sie_file_close(sf.handle)
        sf.handle = C_NULL
    end
    return nothing
end

Base.isopen(sf::SieFile) = sf.handle != C_NULL

Base.open(::Type{SieFile}, path::AbstractString) = SieFile(path)

function Base.open(f::Function, ::Type{SieFile}, path::AbstractString)
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

# Counts
nchannels(sf::SieFile) = Int(L.sie_file_num_channels(_check_open(sf)))
ntests(sf::SieFile)    = Int(L.sie_file_num_tests(_check_open(sf)))

# Indexed access
function channel(sf::SieFile, i::Integer)
    h = _check_open(sf)
    1 <= i <= nchannels(sf) || throw(BoundsError(sf, i))
    p = L.sie_file_channel(h, i - 1)
    p == C_NULL ? throw(BoundsError(sf, i)) : Channel(p, sf)
end

function test(sf::SieFile, i::Integer)
    h = _check_open(sf)
    1 <= i <= ntests(sf) || throw(BoundsError(sf, i))
    p = L.sie_file_test(h, i - 1)
    p == C_NULL ? throw(BoundsError(sf, i)) : Test(p, sf)
end

channels(sf::SieFile) = [channel(sf, i) for i in 1:nchannels(sf)]
tests(sf::SieFile)    = [test(sf, i)    for i in 1:ntests(sf)]

"""
    findchannel(file, id::Integer) -> Channel | nothing

Lookup a channel by its SIE-internal numeric id.
"""
function findchannel(sf::SieFile, cid::Integer)
    p = L.sie_file_find_channel(_check_open(sf), cid)
    p == C_NULL ? nothing : Channel(p, sf)
end

"""
    findtest(file, id::Integer) -> Test | nothing
"""
function findtest(sf::SieFile, tid::Integer)
    p = L.sie_file_find_test(_check_open(sf), tid)
    p == C_NULL ? nothing : Test(p, sf)
end

"""
    containingtest(file, channel) -> Test | nothing

Return the [`Test`](@ref) that owns `channel`, or `nothing` if the channel is
not contained in any test.
"""
function containingtest(sf::SieFile, ch::Channel)
    p = L.sie_file_containing_test(_check_open(sf), ch.handle)
    p == C_NULL ? nothing : Test(p, sf)
end

tags(sf::SieFile) = Tags(sf, Int(L.sie_file_num_tags(_check_open(sf))),
    L.sie_file_tag, nothing)

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
    for d in 1:nd, r in 1:nr
        @inbounds M[r, d] = getfloat64(o, d, r)
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
    read(file::SieFile, dim::Dimension) -> Vector{Float64} | Vector{Vector{UInt8}}

Read the entire data series for a single dimension into a Julia vector.

The element type is chosen from the dimension's column type:

* `:float64` columns return a `Vector{Float64}` of engineering-scaled samples.
* `:raw`     columns return a `Vector{Vector{UInt8}}`, one byte string per
  sample (e.g. CAN frames).

This is the recommended way to pull data: it preserves raw payloads losslessly
and makes per-dimension tags trivially reachable via `tags(dim)`.

# Example
```julia
open(SomatSIE.SieFile, "can.sie") do f
    for ch in channels(f)
        for dim in dimensions(ch)
            data  = read(f, dim)            # typed per-dim vector
            units = get(tags(dim), "core:units", nothing)
            @show name(ch), index(dim), eltype(data), length(data), units
        end
    end
end
```
"""
function Base.read(file::SieFile, dim::Dimension)
    ch = dim.parent::Channel
    d  = index(dim) + 1   # libsie dimension index is 0-based; convert to 1-based
    return spigot(file, ch) do s
        out = next!(s)
        out === nothing && return Float64[]   # empty channel — default to float
        ct = coltype(out, d)
        if ct === :float64
            buf = Float64[]
            while out !== nothing
                nr = numrows(out)
                resize!(buf, length(buf) + nr)
                base = length(buf) - nr
                @inbounds for r in 1:nr
                    buf[base + r] = getfloat64(out, d, r)
                end
                out = next!(s)
            end
            return buf
        elseif ct === :raw
            buf = Vector{Vector{UInt8}}()
            while out !== nothing
                nr = numrows(out)
                @inbounds for r in 1:nr
                    push!(buf, getraw(out, d, r))
                end
                out = next!(s)
            end
            return buf
        else
            error("dimension $(index(dim)) of channel '", name(ch),
                  "' has no data type (:none)")
        end
    end
end

Base.show(io::IO, s::Spigot) = print(io,
    "Spigot(channel=", id(s.channel), isopen(s) ? "" : ", closed", ")")

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
