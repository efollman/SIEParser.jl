# SomatSIE.jl — Julia API Reference

`SomatSIE` is a thin, idiomatic Julia wrapper around
[libsie-z](https://github.com/efollman/libsie-z) (provided by `libsie_jll`)
for reading HBM/Somat eDAQ SIE acquisition files.

The API is organized around four types — [`SieFile`](#siefile),
[`Spigot`](#spigot), [`Stream`](#stream), and [`Histogram`](#histogram) —
plus value/metadata types (`Test`, `Channel`, `Dimension`, `Tag`, `Tags`,
`Output`) and the `SieError` exception.

> The libsie 0.3 ABI is **read-only**: there is no SIE writer.

---

## Table of Contents

- [Library info](#library-info)
- [Errors](#errors)
- [`SieFile`](#siefile)
- [`Test`](#test)
- [`Channel`](#channel)
- [`Dimension`](#dimension)
- [`Tag` and `Tags`](#tag-and-tags)
- [`Spigot` and `Output`](#spigot-and-output)
- [Reading data](#reading-data)
- [`Stream` (incremental ingest)](#stream-incremental-ingest)
- [`Histogram`](#histogram)
- [Quick reference: exported names](#quick-reference-exported-names)

---

## Library info

### `libsie_version() -> String`

Return the version string of the underlying libsie shared library.

```julia
julia> SomatSIE.libsie_version()
"0.3.x"
```

---

## Errors

### `SieError <: Exception`

Thrown when a libsie call returns a non-zero status code.

Fields:

| Field     | Type     | Meaning                                                         |
|-----------|----------|-----------------------------------------------------------------|
| `code`    | `Int`    | Numeric libsie status code.                                     |
| `message` | `String` | Human-readable description from `sie_status_message`.           |

`Base.showerror` prints as `SieError(<code>): <message>`.

---

## `SieFile`

The opened-file handle. Mutable; closed via `close` or its finalizer.

### Constructors / `open`

```julia
SieFile(path)                         # open and return a SieFile
open(SomatSIE.SieFile, path)          # idiomatic alias
open(f, SomatSIE.SieFile, path)       # do-block form (recommended)
```

The do-block form guarantees `close` runs even on exceptions:

```julia
open(SomatSIE.SieFile, "myfile.sie") do f
    for ch in channels(f)
        @show name(ch)
    end
end
```

### `close(file::SieFile)`

Release the underlying libsie file handle. **Idempotent.** After closing,
all borrowed `Test` / `Channel` / `Dimension` / `Tag` references owned by
the file become invalid.

### `isopen(file::SieFile) -> Bool`

`true` while the underlying libsie handle is live.

### `nchannels(file::SieFile) -> Int`

Total number of channels across all tests in the file.

### `ntests(file::SieFile) -> Int`

Total number of tests recorded in the file.

### `channel(file::SieFile, i::Integer) -> Channel`

1-based positional access into the file's channel list. Throws
`BoundsError` for out-of-range `i`.

### `test(file::SieFile, i::Integer) -> Test`

1-based positional access into the file's test list. Throws `BoundsError`
for out-of-range `i`.

### `channels(file::SieFile) -> Vector{Channel}`

Materialize all channels into a Julia `Vector`.

### `tests(file::SieFile) -> Vector{Test}`

Materialize all tests into a Julia `Vector`.

### `findchannel(file::SieFile, id::Integer) -> Union{Channel, Nothing}`

Look up a channel by its SIE-internal numeric id. Returns `nothing` if no
matching channel exists.

### `findtest(file::SieFile, id::Integer) -> Union{Test, Nothing}`

Look up a test by its SIE-internal numeric id.

### `containingtest(file::SieFile, ch::Channel) -> Union{Test, Nothing}`

Return the [`Test`](#test) that owns `ch`, or `nothing` if the channel is
not contained in any test.

### `tags(file::SieFile) -> Tags`

File-level tag collection (see [`Tags`](#tag-and-tags)).

---

## `Test`

A test (acquisition session) within a `SieFile`. Borrowed from the file —
do not use after the file is closed.

> Named `Test` for SIE convention. Reference as `SomatSIE.Test` to avoid
> clashing with `Base.Test`.

### `id(test::Test) -> Int`

SIE-internal numeric test id.

### `name(test::Test) -> String`

Human-readable test name.

### `nchannels(test::Test) -> Int`

Number of channels owned by this test.

### `channel(test::Test, i::Integer) -> Channel`

1-based positional access to a channel within the test.

### `channels(test::Test) -> Vector{Channel}`

Materialize all channels of the test into a `Vector`.

### `tags(test::Test) -> Tags`

Test-level tag collection.

---

## `Channel`

A data series within a `SieFile`. Borrowed from the file.

### `id(ch::Channel) -> Int`

SIE-internal channel id.

### `testid(ch::Channel) -> Int`

Id of the owning test.

### `name(ch::Channel) -> String`

Channel name.

### `numdims(ch::Channel) -> Int`

Number of dimensions ("columns"). For a sequential time-history channel
this is typically 2 (`0` = time, `1` = value); CAN channels can have
mixed numeric + raw dimensions.

### `dimension(ch::Channel, i::Integer) -> Dimension`

1-based positional access to a dimension.

### `dimensions(ch::Channel) -> Vector{Dimension}`

All dimensions, materialized into a `Vector`.

### `tags(ch::Channel) -> Tags`

Channel-level tag collection.

---

## `Dimension`

A single axis ("column") of a `Channel`. Borrowed from the channel.

### `index(dim::Dimension) -> Int`

**Zero-based** dimension index, exactly as libsie reports it. (0 is
typically time, 1 is value for sequential time-series channels.) Note
that this is *not* converted to 1-based — keep the convention in mind.

### `name(dim::Dimension) -> String`

Dimension name.

### `tags(dim::Dimension) -> Tags`

Per-dimension tag collection. Useful for `core:units`, `core:sample_rate`,
etc.

---

## `Tag` and `Tags`

### `Tag`

A single key/value metadata entry attached to a `SieFile`, `Test`,
`Channel`, or `Dimension`. Borrowed from its parent — no cleanup required.

| Function                       | Returns                                | Description                                                     |
|--------------------------------|----------------------------------------|-----------------------------------------------------------------|
| `key(t::Tag)`                  | `String`                               | The tag key.                                                    |
| `isstring(t::Tag)`             | `Bool`                                 | `true` if the value is textual.                                 |
| `isbinary(t::Tag)`             | `Bool`                                 | `true` if the value is a binary blob.                           |
| `valuesize(t::Tag)`            | `Int`                                  | Size in bytes of the value payload.                             |
| `value(t::Tag)`                | `String` or `Vector{UInt8}`            | `String` for textual tags, copy of the bytes for binary tags.   |
| `group(t::Tag)`                | `Int`                                  | Group ordinal that owns this tag.                               |
| `isfromgroup(t::Tag)`          | `Bool`                                 | `true` if the tag was inherited from a group rather than direct.|

### `Tags`

A lazy, dict-like view of the tag list owned by a parent (`SieFile`,
`Test`, `Channel`, or `Dimension`). Supports both positional and keyed
access:

| Operation                     | Result                                                    |
|-------------------------------|-----------------------------------------------------------|
| `length(tags)`                | Number of tags.                                           |
| `iterate(tags)`               | Yields `Tag` values in libsie order.                      |
| `tags[i::Integer]`            | 1-based positional access — returns `Tag`.                |
| `tags[k::AbstractString]`     | Keyed access — returns `Tag` or throws `KeyError`.        |
| `get(tags, k, default)`       | Keyed access with a fallback value.                       |
| `haskey(tags, k)`             | Membership test by key.                                   |

```julia
ts = tags(ch)
sr = get(ts, "core:sample_rate", nothing)
units = haskey(ts, "core:units") ? value(ts["core:units"]) : ""
```

---

## `Spigot` and `Output`

### `Spigot`

A per-channel data pipeline. Mutable; close with `close` or via the
do-block form of [`spigot`](#spigotfile-channel---spigot).

### `Spigot(file, ch)` / `spigot(file, ch) -> Spigot`

Attach a new spigot reading `ch` from `file`.

### `spigot(f::Function, file, ch)`

Do-block form. Always closes the spigot:

```julia
spigot(f, ch) do s
    for out in s
        # use out
    end
end
```

### `close(s::Spigot)` / `isopen(s::Spigot) -> Bool`

Release / inspect the spigot handle. Idempotent.

### `next!(s::Spigot) -> Union{Output, Nothing}`

Pull the next data block. Returns `nothing` at end-of-stream. Each call
**invalidates** the previously returned `Output`.

### Iteration

`Spigot` iterates yielding `Output` blocks. Iterator size is
`Base.SizeUnknown()`, element type is `Output`.

```julia
for out in s
    # process out — invalidated on the next iteration
end
```

### `numblocks(s::Spigot) -> Int`

Total number of blocks the spigot will (or did) emit.

### `reset!(s::Spigot) -> Spigot`

Rewind the spigot to its first block.

### `disable_transforms!(s::Spigot, disable::Bool = true) -> Spigot`

Disable (or re-enable) engineering-unit transforms — useful when raw
counts are wanted.

### `set_scan_limit!(s::Spigot, limit::Integer) -> Spigot`

Bound the maximum number of scans the spigot will read per block.

### Other `Spigot` methods

* `position(s::Spigot) -> Int` — current byte position.
* `seek(s::Spigot, target) -> Spigot` — seek to a byte offset.

> `position` and `seek` are not exported; access via `Base.position` /
> `Base.seek`.

### `Output`

A single decoded data block produced by a `Spigot`. **Owned by the
spigot — invalidated by the next `read` / `iterate` on that spigot.**

| Function                        | Returns         | Description                                                |
|---------------------------------|-----------------|------------------------------------------------------------|
| `numrows(out::Output)`          | `Int`           | Number of scan rows in the block.                          |
| `numdims(out::Output)`          | `Int`           | Number of dimensions in the block.                         |
| `block(out::Output)`            | `Int`           | Block index within the channel.                            |
| `coltype(out, dim)`             | `Symbol`        | `:float64`, `:raw`, or `:none` for the 1-based dimension.  |
| `getfloat64(out, dim, row)`     | `Float64`       | Float sample at 1-based `(dim, row)`. Throws on `:raw`.    |
| `getraw(out, dim, row)`         | `Vector{UInt8}` | Copy of the raw payload at 1-based `(dim, row)`.           |
| `Matrix(out::Output)`           | `Matrix{Float64}` | Convert all `:float64` columns to a `(numrows, numdims)` matrix. Throws if any dimension is `:raw`. |
| `size(out::Output)`             | `Tuple`         | `(numrows, numdims)`.                                      |

For mixed-type outputs (e.g. CAN channels with a raw frame dimension),
**iterate the spigot per-block** and call `getfloat64` / `getraw` per
dimension — do not use `Matrix(out)`.

---

## Reading data

### `read(file::SieFile, dim::Dimension) -> Vector`

Read the entire data series for a single dimension into a Julia vector.
The element type is chosen from the dimension's column type:

* `:float64` columns return a `Vector{Float64}` of engineering-scaled
  samples.
* `:raw` columns return a `Vector{Vector{UInt8}}`, one byte string per
  sample (e.g. CAN frames).
* `:none` raises an error.

This is the recommended way to pull data: it preserves raw payloads
losslessly and makes per-dimension tags trivially reachable via
`tags(dim)`.

```julia
open(SomatSIE.SieFile, "can.sie") do f
    for ch in channels(f)
        for dim in dimensions(ch)
            data  = read(f, dim)
            units = get(tags(dim), "core:units", nothing)
            @show name(ch), index(dim), eltype(data), length(data), units
        end
    end
end
```

### `read!(file::SieFile, dim::Dimension, dest::AbstractVector{Float64}) -> dest`

In-place variant of `read` for `:float64` dimensions. `dest` is resized
to fit the channel and filled with engineering-scaled samples. Uses the
libsie `sie_output_get_float64_range` bulk getter so each block costs a
single `ccall` instead of one per sample.

Throws on `:raw`/`:none` columns.

### `numrows(file::SieFile, ch::Channel) -> Int`

Total number of samples in `ch` **without materializing the data**.
Walks the channel's spigot once, summing `numrows(out)` per block — one
ccall per block rather than per sample, so cheap even for multi-million
row channels.

Useful when constructing a time axis for a sequential time-history
channel directly from `core:sample_rate` instead of reading dim-0.

---

## `Stream` (incremental ingest)

Incremental SIE block parser. Useful when SIE data arrives over a network
or is being produced in real time.

### `Stream()`

Create a new empty stream parser. Closed via `close` or finalizer.

### `close(s::Stream)`

Release the underlying handle. Idempotent.

### `add!(s::Stream, bytes::AbstractVector{UInt8}) -> Int`

Feed `bytes` into the stream. Returns the number of bytes **consumed**.
Bytes not consumed should be re-presented in the next call together with
new data.

### Group inspection

| Function                                  | Returns | Description                                  |
|-------------------------------------------|---------|----------------------------------------------|
| `numgroups(s::Stream)`                    | `Int`   | Number of groups discovered so far.          |
| `group_numblocks(s::Stream, gid)`         | `Int`   | Number of blocks in group `gid`.             |
| `group_numbytes(s::Stream, gid)`          | `Int`   | Total bytes in group `gid`.                  |
| `group_isclosed(s::Stream, gid)`          | `Bool`  | `true` once the group's terminating block has been seen. |

`gid` is the libsie-native (zero-based) group ordinal returned/expected
by the C ABI — it is **not** translated to 1-based here.

---

## `Histogram`

In-memory view of a histogram-typed channel.

### `Histogram(file::SieFile, ch::Channel)`

Build the histogram. Closed via `close` or finalizer.

### `close(h::Histogram)`

Release the underlying handle. Idempotent.

### `numdims(h::Histogram) -> Int`

Number of histogram dimensions.

### `totalsize(h::Histogram) -> Int`

Total number of bins across all dimensions (i.e. the product of per-dim
bin counts).

### `numbins(h::Histogram, dim::Integer) -> Int`

Number of bins along the 1-based dimension `dim`.

### `getbin(h::Histogram, indices) -> Float64`

Bin count at `indices`, where `indices` is a tuple/vector of 1-based bin
indices — one per dimension. Throws if its length does not match
`numdims(h)`.

### `bounds(h::Histogram, dim::Integer) -> (lower, upper)`

Returns two `Vector{Float64}` arrays of length `numbins(h, dim)` giving
the lower and upper bin edges along dimension `dim`.

---

## Quick reference: exported names

Types:

`SieFile`, `Spigot`, `Stream`, `Histogram`, `Tag`, `Tags`, `Output`,
`SieError`

File / test / channel navigation:

`channels`, `tests`, `tags`, `dimensions`, `dimension`, `channel`,
`test`, `findchannel`, `findtest`, `containingtest`

Spigots and outputs:

`spigot`, `next!`, `numblocks`, `numrows`, `numdims`, `block`,
`coltype`, `getfloat64`, `getraw`

Tag inspection:

`isstring`, `isbinary`, `value`, `key`, `valuesize`, `group`,
`isfromgroup`

Identity / counts:

`id`, `testid`, `name`, `index`, `nchannels`, `ntests`

Spigot control:

`reset!`, `disable_transforms!`, `set_scan_limit!`

Streams:

`add!`, `numgroups`, `group_numblocks`, `group_numbytes`,
`group_isclosed`

Histograms:

`numbins`, `totalsize`, `getbin`, `bounds`

Library info:

`libsie_version`
