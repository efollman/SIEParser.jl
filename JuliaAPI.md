# SomatSIE.jl — Julia API Reference

`SomatSIE` is a thin, idiomatic Julia wrapper around
[libsie-z](https://github.com/efollman/libsie-z) (provided by `libsie_jll`)
for reading HBM/Somat eDAQ SIE acquisition files.

The public API is intentionally small and is organized around a single
top-level type — [`SieFile`](#siefile) — plus value/metadata types
(`Test`, `Channel`, `Dimension`, `Tag`, `Tags`) and the `SieError`
exception. Per-dimension data is materialized with
[`read(file, dim)`](#reading-data).

> The libsie 0.3 ABI is **read-only**: there is no SIE writer.

> Spigot / streaming / histogram functionality is implemented but kept
> internal. It is reachable as `SomatSIE.spigot`, `SomatSIE.Stream`,
> `SomatSIE.Histogram`, etc., for advanced use, but is not part of the
> stable exported surface.

---

## Table of Contents

- [Library info](#library-info)
- [Errors](#errors)
- [`SieFile`](#siefile)
- [`Test`](#test)
- [`Channel`](#channel)
- [`Dimension`](#dimension)
- [`Tag` and `Tags`](#tag-and-tags)
- [Reading data](#reading-data)
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

### `channels(file::SieFile) -> Vector{Channel}`

All channels in the file, materialized into a `Vector`. Use `length` to
get a count.

### `tests(file::SieFile) -> Vector{Test}`

All tests in the file, materialized into a `Vector`. Use `length` to get
a count.

### `findchannel(file::SieFile, id::Integer) -> Union{Channel, Nothing}`

Look up a channel by its SIE-internal numeric id (the value returned by
[`id(::Channel)`](#channel)). Returns `nothing` if no matching channel
exists.

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

### `channels(test::Test) -> Vector{Channel}`

All channels owned by the test, as a `Vector`. Use `length` for a count.

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

### `dimensions(ch::Channel) -> Vector{Dimension}`

All dimensions ("columns") of the channel, as a `Vector`. Use `length`
for a count. For a sequential time-history channel this is typically
length 2 (`id == 1` is time, `id == 2` is value); CAN channels can have
mixed numeric + raw dimensions.

### `tags(ch::Channel) -> Tags`

Channel-level tag collection.

---

## `Dimension`

A single axis ("column") of a `Channel`. Borrowed from the channel.

### `id(dim::Dimension) -> Int`

**1-based** dimension identifier (1 is typically time, 2 is value for
sequential time-series channels). Note: this differs from the libsie/file
0-based convention — Julia code is uniformly 1-based.

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
            @show name(ch), id(dim), eltype(data), length(data), units
        end
    end
end
```

### `read!(file::SieFile, dim::Dimension, dest::AbstractVector{Float64}) -> dest`

In-place variant of `read` for `:float64` dimensions. `dest` is resized
to fit the channel and filled with engineering-scaled samples. Uses
libsie's bulk getter so each block costs a single `ccall` instead of one
per sample.

Throws on `:raw`/`:none` columns.

---

## Quick reference: exported names

Types:

`SieFile`, `Tag`, `Tags`, `SieError`

File / test / channel / dimension navigation:

`channels`, `tests`, `dimensions`, `tags`,
`findchannel`, `findtest`, `containingtest`

Identity:

`id`, `testid`, `name`

Tag inspection:

`key`, `value`, `valuesize`, `isstring`, `isbinary`, `group`,
`isfromgroup`

Library info:

`libsie_version`

> Counts are obtained via `length(channels(f))`, `length(tests(f))`,
> `length(dimensions(ch))`, `length(tags(x))` — there are no separate
> `nchannels` / `ntests` / `numdims` exports.

> Per-element positional access (`channel(file, i)`, `test(file, i)`,
> `dimension(ch, i)`, `channel(test, i)`) is not exported. Index the
> vector returned by `channels` / `tests` / `dimensions` instead — for
> example, `channels(f)[1]`.

> Spigot, Output, Stream, and Histogram types and functions are kept
> internal (`SomatSIE.spigot`, `SomatSIE.Stream`, `SomatSIE.Histogram`,
> …). Prefer `read(file, dim)` for typical use; the streaming layer is
> reserved for future optimization work.
