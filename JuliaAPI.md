# SomatSIE.jl — Julia API Reference

`SomatSIE` is a thin, idiomatic Julia wrapper around
[libsie-z](https://github.com/efollman/libsie-z) (provided by `libsie_jll`)
for reading HBM/Somat eDAQ SIE acquisition files.

The public API is intentionally small and is organized around a single
top-level type — [`SieFile`](#siefile) — plus value/metadata types
(`Test`, `Channel`, `Dimension`, `Tags`) and the `SieError` exception.
Files are opened with [`opensie`](#siefile); per-dimension data is
materialized with [`readDim`](#reading-data).

> The libsie 0.3 ABI is **read-only**: there is no SIE writer.

> Spigot / streaming / histogram functionality is implemented but kept
> internal. It is reachable as `SomatSIE.spigot`, `SomatSIE.Stream`,
> `SomatSIE.Histogram`, etc., for advanced use, but is not part of the
> stable exported surface.

> Public accessors on `SieFile`, `Test`, `Channel`, and `Dimension` are
> exposed as **dot properties** \u2014 `f.tests`, `t.channels`,
> `ch.dimensions`, `dim.id`, `x.name`, `x.tags`, etc. There are no
> matching exported functions; use the property syntax everywhere.

---

## Table of Contents

- [Library info](#library-info)
- [Errors](#errors)
- [`SieFile`](#siefile)
- [`Test`](#test)
- [`Channel`](#channel)
- [`Dimension`](#dimension)
- [`Tags`](#tags)
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

The opened-file handle. Mutable; closed automatically by the do-block
form of [`opensie`](#opening-a-file-opensie) (or its finalizer).

### Opening a file: `opensie`

```julia
opensie("myfile.sie") do f
    for t in f.tests, ch in t.channels
        @show ch.name
    end
end
```

The do-block form guarantees `close` runs even on exceptions \u2014 use it
for all file access.

### `close(file::SieFile)`

Release the underlying libsie file handle. **Idempotent.** After closing,
all borrowed `Test` / `Channel` / `Dimension` / `Tag` references owned by
the file become invalid.

### `isopen(file::SieFile) -> Bool`

`true` while the underlying libsie handle is live.

### `file.tests -> Vector{Test}`

All tests in the file, materialized into a `Vector`. Use `length` to get
a count. Channels live under tests — there is no `file.channels`
because channel ids may collide between tests; iterate via
`[ch for t in f.tests for ch in t.channels]`.

### `file.tags -> Tags`

File-level tag dictionary (see [`Tags`](#tags)).

---

## `Test`

A test (acquisition session) within a `SieFile`. Borrowed from the file —
do not use after the file is closed.

> Named `Test` for SIE convention. Reference as `SomatSIE.Test` to avoid
> clashing with `Base.Test`.

### `test.id -> Int`

SIE-internal numeric test id.

### `test.name -> String`

Human-readable test name.

### `test.channels -> Vector{Channel}`

All channels owned by the test, as a `Vector`. Use `length` for a count.

### `findchannel(test::Test, name::AbstractString) -> Union{Channel, Nothing}`

Look up a channel within `test` by its name. Exact, case-sensitive match.
Returns `nothing` if no channel has that name; if multiple channels
share the name, the first one is returned.

### `test.tags -> Tags`

Test-level tag dictionary.

---

## `Channel`

A data series within a `SieFile`. Borrowed from the file.

### `ch.id -> Int`

SIE-internal channel id.

### `ch.name -> String`

Channel name.

### `ch.dimensions -> Vector{Dimension}`

All dimensions ("columns") of the channel, as a `Vector`. Use `length`
for a count. For a sequential time-history channel this is typically
length 2 (`dim.id == 1` is time, `dim.id == 2` is value); CAN channels
can have mixed numeric + raw dimensions.

### `ch.tags -> Tags`

Channel-level tag dictionary.

---

## `Dimension`

A single axis ("column") of a `Channel`. Borrowed from the channel.

### `dim.id -> Int`

**1-based** dimension identifier (1 is typically time, 2 is value for
sequential time-series channels). Note: this differs from the libsie/file
0-based convention — Julia code is uniformly 1-based.

### `dim.name -> String`

Dimension name.

### `dim.tags -> Tags`

Per-dimension tag dictionary. Useful for `core:units`, `core:sample_rate`,
etc.

---

## `Tags`

`Tags` is a type alias for `Dict{String, Union{String, Vector{UInt8}}}`.
Reading `x.tags` on a `SieFile`, `Test`, `Channel`, or `Dimension`
returns one of these dictionaries, fully materialized from the libsie
tag list.

Values are `String` for textual tags or `Vector{UInt8}` for binary blobs
— dispatch on the result type when needed.

Use the standard `Dict` API:

| Operation                     | Result                                                    |
|-------------------------------|-----------------------------------------------------------|
| `length(tags)`                | Number of tags.                                           |
| `iterate(tags)`               | Yields `key => value` pairs.                              |
| `tags[k::AbstractString]`     | Keyed access — returns the value or throws `KeyError`.    |
| `get(tags, k, default)`       | Keyed access with a fallback value.                       |
| `haskey(tags, k)`             | Membership test by key.                                   |
| `keys(tags)` / `values(tags)` | Standard `Dict` views.                                    |

```julia
ts = ch.tags
sr = get(ts, "core:sample_rate", nothing)
units = haskey(ts, "core:units") ? ts["core:units"] : ""
```

---

## Reading data

### `readDim(dim::Dimension) -> Vector`

Read the entire data series for a single dimension into a Julia vector.
The element type is chosen from the dimension's column type:

* `:float64` columns return a `Vector{Float64}` of engineering-scaled
  samples.
* `:raw` columns return a `Vector{Vector{UInt8}}`, one byte string per
  sample (e.g. CAN frames).
* `:none` raises an error.

`readDim` recovers the owning `SieFile` from the `Dimension` itself, so
you never need to thread the file handle through the call.

Internally `readDim` walks the channel's spigot once and pulls each
block via the libsie bulk getters (`sie_output_get_float64_range` /
`sie_output_get_raw_range`) — one `ccall` per block, not per sample —
so it is cheap even for multi-million-row channels.

```julia
opensie("can.sie") do f
    for t in f.tests, ch in t.channels
        for dim in ch.dimensions
            data  = readDim(dim)
            units = get(dim.tags, "core:units", nothing)
            @show ch.name, dim.id, eltype(data), length(data), units
        end
    end
end
```

---

## Quick reference: exported names

Types:

`SieFile`, `Tags`, `SieError`

Functions:

`opensie`, `readDim`, `findchannel`, `libsie_version`

Navigation and identity are accessed as **dot properties** on the
returned types (`f.tests`, `f.tags`, `t.id`, `t.name`, `t.channels`,
`t.tags`, `ch.id`, `ch.name`, `ch.dimensions`, `ch.tags`, `dim.id`,
`dim.name`, `dim.tags`) — there are no exported `tests` / `channels` /
`dimensions` / `tags` / `id` / `name` functions.

> Counts are obtained via `length(f.tests)`, `length(t.channels)`,
> `length(ch.dimensions)`, `length(x.tags)`.
>
> Channels live under tests. `f.channels` raises an error because
> channel ids may collide between tests; iterate with
> `for t in f.tests, ch in t.channels` (or build the flat list with
> `[ch for t in f.tests for ch in t.channels]`).

> Per-element positional access is via vector indexing, e.g.
> `f.tests[1]`, `f.tests[1].channels[1]`, `ch.dimensions[1]`.

> Spigot, Output, Stream, and Histogram types and functions are kept
> internal (`SomatSIE.spigot`, `SomatSIE.Stream`, `SomatSIE.Histogram`,
> …). Prefer `readDim(dim)` for typical use; the streaming layer is
> reserved for future optimization work.
