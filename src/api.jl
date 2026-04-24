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

Access identity and metadata via dot syntax: `dim.id`, `dim.name`,
`dim.tags`. Use [`readDim`](@ref) to materialize the dimension's entire
data series as a typed Julia vector.

`dim.id` is **1-based** (1 is typically time, 2 is value for sequential
time-series channels) — the libsie/file underlying convention is
0-based, but Julia code is uniformly 1-based.
"""
struct Dimension
    handle::Ptr{Cvoid}
    parent::Any  # Channel — typed Any to avoid forward declaration; see ch field below
end

_id(d::Dimension)   = Int(L.sie_dimension_index(d.handle)) + 1
_name(d::Dimension) = _ptrlen_to_string(L.sie_dimension_name, d.handle)
_tags(d::Dimension) = _build_tags(d.handle,
    Int(L.sie_dimension_num_tags(d.handle)), L.sie_dimension_tag)

function Base.getproperty(d::Dimension, sym::Symbol)
    sym === :id   && return _id(d)
    sym === :name && return _name(d)
    sym === :tags && return _tags(d)
    return getfield(d, sym)
end
Base.propertynames(::Dimension, private::Bool = false) =
    private ? (:id, :name, :tags, :handle, :parent) : (:id, :name, :tags)

Base.show(io::IO, d::Dimension) =
    print(io, "Dimension(", _id(d), ", ", repr(_name(d)), ")")

# ── Channel ─────────────────────────────────────────────────────────────────

"""
    Channel

A data series within a [`SieFile`](@ref). Borrowed from the file.

Access via dot syntax: `ch.id`, `ch.name`, `ch.dimensions`, `ch.tags`.
"""
struct Channel
    handle::Ptr{Cvoid}
    parent::Any   # keeps SieFile alive
end

_id(c::Channel)       = Int(L.sie_channel_id(c.handle))
_name(c::Channel)     = _ptrlen_to_string(L.sie_channel_name, c.handle)
_numdims(c::Channel)  = Int(L.sie_channel_num_dims(c.handle))
_tags(c::Channel)     = _build_tags(c.handle,
    Int(L.sie_channel_num_tags(c.handle)), L.sie_channel_tag)

function _dimension(c::Channel, i::Integer)
    1 <= i <= _numdims(c) || throw(BoundsError(c, i))
    h = L.sie_channel_dimension(c.handle, i - 1)
    h == C_NULL ? throw(BoundsError(c, i)) : Dimension(h, c)
end

_dimensions(c::Channel) = [_dimension(c, i) for i in 1:_numdims(c)]

function Base.getproperty(c::Channel, sym::Symbol)
    sym === :id         && return _id(c)
    sym === :name       && return _name(c)
    sym === :dimensions && return _dimensions(c)
    sym === :tags       && return _tags(c)
    return getfield(c, sym)
end
Base.propertynames(::Channel, private::Bool = false) =
    private ? (:id, :name, :dimensions, :tags, :handle, :parent) :
              (:id, :name, :dimensions, :tags)

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

_id(t::Test)        = Int(L.sie_test_id(t.handle))
_name(t::Test)      = _ptrlen_to_string(L.sie_test_name, t.handle)
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
    sym === :name     && return _name(t)
    sym === :channels && return _channels(t)
    sym === :tags     && return _tags(t)
    return getfield(t, sym)
end
Base.propertynames(::Test, private::Bool = false) =
    private ? (:id, :name, :channels, :tags, :handle, :parent) :
              (:id, :name, :channels, :tags)

Base.show(io::IO, t::Test) =
    print(io, "Test(id=", _id(t), ", name=", repr(_name(t)),
              ", nchannels=", _nchannels(t), ")")

# ── SieFile ─────────────────────────────────────────────────────────────────

"""
    SieFile

An opened SIE file handle. Open one with [`opensie`](@ref) using the
do-block form so the underlying libsie handle is released automatically:

    opensie("myfile.sie") do f
        for t in f.tests, ch in t.channels
            for dim in ch.dimensions
                println(ch.name, " dim ", dim.id, ": ", readDim(dim))
            end
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
    private ? (:tests, :tags, :path, :handle) : (:tests, :tags, :path)

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
    readDim(dim::Dimension) -> Vector{Float64} | Vector{Vector{UInt8}}

Read the entire data series for a single dimension into a Julia vector.

The element type is chosen from the dimension's column type:

* `:float64` columns return a `Vector{Float64}` of engineering-scaled samples.
* `:raw`     columns return a `Vector{Vector{UInt8}}`, one byte string per
  sample (e.g. CAN frames).

Internally walks the channel's spigot once and pulls each block via the
libsie bulk getters (`sie_output_get_float64_range` /
`sie_output_get_raw_range`), so each block costs a single `ccall` instead
of one per sample.

# Example
```julia
opensie("can.sie") do f
    for ch in channels(f)
        for dim in dimensions(ch)
            data  = readDim(dim)            # typed per-dim vector
            units = get(tags(dim), "core:units", nothing)
            @show name(ch), id(dim), eltype(data), length(data), units
        end
    end
end
```
"""
function readDim(dim::Dimension)
    ch   = dim.parent::Channel
    file = ch.parent::SieFile
    d    = _id(dim)   # 1-based
    return spigot(file, ch) do s
        out = next!(s)
        out === nothing && return Float64[]   # empty channel — default to float
        ct = coltype(out, d)
        if ct === :float64
            buf     = Float64[]
            d0      = Csize_t(d - 1)
            written = Ref{Csize_t}(0)
            while out !== nothing
                nr   = numrows(out)
                if nr > 0
                    base = length(buf)
                    resize!(buf, base + nr)
                    GC.@preserve buf _check(L.sie_output_get_float64_range(
                        out.handle, d0, Csize_t(0), Csize_t(nr),
                        pointer(buf, base + 1), written))
                end
                out = next!(s)
            end
            return buf
        elseif ct === :raw
            buf     = Vector{Vector{UInt8}}()
            d0      = Csize_t(d - 1)
            written = Ref{Csize_t}(0)
            ptrs    = Vector{Ptr{UInt8}}()
            sizes   = Vector{UInt32}()
            while out !== nothing
                nr = numrows(out)
                if nr > 0
                    resize!(ptrs,  nr)
                    resize!(sizes, nr)
                    GC.@preserve ptrs sizes _check(L.sie_output_get_raw_range(
                        out.handle, d0, Csize_t(0), Csize_t(nr),
                        pointer(ptrs), pointer(sizes), written))
                    @inbounds for i in 1:nr
                        p, n = ptrs[i], Int(sizes[i])
                        push!(buf, (p == C_NULL || n == 0) ? UInt8[] :
                            copy(unsafe_wrap(Array, p, n; own = false)))
                    end
                end
                out = next!(s)
            end
            return buf
        else
            error("dimension $(id(dim)) of channel '", name(ch),
                  "' has no data type (:none)")
        end
    end
end

"""
    numrows(file::SieFile, ch::Channel) -> Int

Total number of samples in `ch` without materializing the data. Walks the
channel's spigot once, summing `numrows(out)` per block — one ccall per
block rather than per sample, so cheap even for multi-million-row channels.

Useful when constructing a time axis for a sequential time-history channel
directly from `core:sample_rate` instead of reading dim-0.
"""
function numrows(file::SieFile, ch::Channel)
    n = 0
    spigot(file, ch) do s
        out = next!(s)
        while out !== nothing
            n += numrows(out)
            out = next!(s)
        end
    end
    return n
end

Base.show(io::IO, s::Spigot) = print(io,
    "Spigot(channel=", _id(s.channel), isopen(s) ? "" : ", closed", ")")

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
