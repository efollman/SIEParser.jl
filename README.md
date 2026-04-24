# SomatSIE.jl

[![Build Status](https://github.com/efollman/SomatSIE.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/efollman/SomatSIE.jl/actions/workflows/CI.yml?query=branch%3Amaster)

`SomatSIE.jl` is a Julia wrapper around [libsie-z](https://github.com/efollman/libsie-z) — a Zig port of HBM/Somat's `libsie` library for reading SIE files produced by eDAQ acquisition equipment. The shared library binaries are supplied by [`libsie_jll`](https://github.com/efollman/libsie_jll.jl); this package provides idiomatic Julia types, iteration, and `read`/`open`/`close` semantics on top of the C ABI.

## Installation

```julia
] add SomatSIE
```

## Quick start

```julia
using SomatSIE

open(SomatSIE.SieFile, "myfile.sie") do f
    @show libsie_version()
    println("file: ", length(channels(f)), " channels in ", length(tests(f)), " tests")

    for ch in channels(f)
        for dim in dimensions(ch)
            # Per-dimension read returns a typed Julia vector:
            #   * `:float64` columns -> Vector{Float64} of engineering values
            #   * `:raw`     columns -> Vector{Vector{UInt8}} (e.g. CAN frames)
            data  = read(f, dim)
            units = get(tags(dim), "core:units", nothing)
            println("  ", name(ch), " dim ", id(dim),
                    "  ", typeof(data), " len=", length(data),
                    units === nothing ? "" : "  units=" * value(units))
        end
    end
end
```

For sequential time-series channels, dimension `id == 1` is typically time and
dimension `id == 2` is the engineering value — read each separately and pair
them in your own code.

## Concepts

| Type | Purpose |
|------|---------|
| `SieFile` | An opened SIE file. Owns the underlying handle; `close` it (or use `open(SieFile, path) do f ... end`). |
| `SomatSIE.Test` | A test (acquisition session) within a file. Borrowed. |
| `SomatSIE.Channel` | A data series. Borrowed. |
| `SomatSIE.Dimension` | A single column/axis of a channel. Borrowed. |
| `SomatSIE.Tag` | A key/value metadata entry. Value may be `String` or `Vector{UInt8}`. Borrowed. |

Tags behave like a hybrid array/dict:

```julia
ts = tags(channel)            # SomatSIE.Tags collection
length(ts)                    # number of tags
for t in ts; @show key(t), value(t); end
ts[1]                         # by 1-based index -> Tag
ts["core:sample_rate"]        # by key -> Tag (throws KeyError if missing)
get(ts, "core:units", nothing)
haskey(ts, "core:schema")
```

## API surface

Core types: `SieFile`, `Tag`, `Tags`, `SieError`, plus the unexported
`SomatSIE.Test`, `SomatSIE.Channel`, `SomatSIE.Dimension`.

Navigation: `channels`, `tests`, `dimensions`, `tags`, `findchannel`,
`findtest`, `containingtest`. Use `length(channels(f))` etc. for counts;
index the returned `Vector` directly for positional access.

Identity: `id`, `testid`, `name`. Note `id(::Dimension)` is **1-based**
(1 is typically time, 2 is value) — unlike libsie's underlying 0-based
convention.

Reading data: `read(file, dim)` — returns `Vector{Float64}` for float
columns or `Vector{Vector{UInt8}}` for raw columns. `read!(file, dim,
dest)` for in-place float reads.

Tag inspection: `key`, `value`, `valuesize`, `isstring`, `isbinary`,
`group`, `isfromgroup`.

Library info: `libsie_version`.

> Spigot, Output, Stream, and Histogram are intentionally kept internal
> (`SomatSIE.spigot`, `SomatSIE.Stream`, `SomatSIE.Histogram`, …) so the
> public surface stays small. Prefer `read(file, dim)`; the streaming
> layer is reserved for future optimization work.

## Limitations

The C ABI exposed by `libsie_jll` (v0.3) now includes writer functions, however they are low level functions geared for appending blocks to a file stream, or removing channels from a file ect. — substantial work would have to be done to support writing a file from scratch, including writing the xml headers and decoders from scratch. Since the initial purpouse of this library is simply to be able to extract data from this arcane format, this functionality will remain unimplemented.

## Versioning

This is a major rewrite (v0.3). Earlier `0.x` versions of `SomatSIE.jl` parsed SIE files in pure Julia and returned a nested `Dict` from `parseSIE(path)`. That API is gone — use `read(open(SieFile, path) do f ... end, dim)` (or the explicit form) and walk the `file → channel → dimension` tree.

## License

MIT, matching the original project. The underlying `libsie-z` library is LGPL 2.1.
