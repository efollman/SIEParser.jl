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
    println("file: ", nchannels(f), " channels in ", ntests(f), " tests")

    for ch in channels(f)
        for dim in dimensions(ch)
            # Per-dimension read returns a typed Julia vector:
            #   * `:float64` columns -> Vector{Float64} of engineering values
            #   * `:raw`     columns -> Vector{Vector{UInt8}} (e.g. CAN frames)
            data  = read(f, dim)
            units = get(tags(dim), "core:units", nothing)
            println("  ", name(ch), " dim ", index(dim),
                    "  ", typeof(data), " len=", length(data),
                    units === nothing ? "" : "  units=" * value(units))
        end
    end
end
```

For sequential time-series channels, dimension index 0 is typically time and
dimension index 1 is the engineering value — read each separately and pair
them in your own code.

For large files where you do not want to materialize everything at once, iterate the spigot directly to get one block at a time:

```julia
spigot(file, channel) do s
    for out in s             # `out` is a `SomatSIE.Output`, valid until the next iteration
        nr = numrows(out)
        for r in 1:nr
            t = getfloat64(out, 1, r)   # dimension 1 = time (usually)
            v = getfloat64(out, 2, r)   # dimension 2 = data (usually)
            # ...
        end
    end
end
```

## Concepts

| Type | Purpose |
|------|---------|
| `SieFile` | An opened SIE file. Owns the underlying handle; `close` it (or use `open(SieFile, path) do f ... end`). |
| `SomatSIE.Test` | A test (acquisition session) within a file. Borrowed. |
| `SomatSIE.Channel` | A data series. Borrowed. |
| `SomatSIE.Dimension` | A single column/axis of a channel. Borrowed. |
| `SomatSIE.Tag` | A key/value metadata entry. Value may be `String` or `Vector{UInt8}`. Borrowed. |
| `Spigot` | A per-channel data pipeline. Iterate to get `Output` blocks, or `read` it for a `Matrix{Float64}`. |
| `Output` | A decoded data block. **Invalidated by the next `next!` / iteration on the spigot.** |
| `Stream` | Incremental SIE block parser for streaming/network ingest. |
| `Histogram` | Materialized histogram-channel data. |

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

Core types: `SieFile`, `Spigot`, `Stream`, `Histogram`, `Output`, `Tag`, `Tags`, `SieError`, plus the unexported `SomatSIE.Test`, `SomatSIE.Channel`, `SomatSIE.Dimension`.

Reading & navigation: `channels`, `tests`, `tags`, `dimensions`, `dimension`, `channel`, `test`, `findchannel`, `findtest`, `containingtest`, `nchannels`, `ntests`.

Spigot: `spigot`, `next!`, `numblocks`, `reset!`, `disable_transforms!`, `set_scan_limit!`, plus extensions of `Base.position`, `Base.seek`, `Base.close`, `Base.iterate`.

Reading data: `read(file, dim)` — returns `Vector{Float64}` for float columns or `Vector{Vector{UInt8}}` for raw columns. Iterate the spigot directly for streaming/per-block access.

Output access: `numrows`, `numdims`, `block`, `coltype`, `getfloat64`, `getraw`, plus `Base.Matrix(out)` for an all-float64-columns copy (throws on raw columns).

Tags: `key`, `value`, `valuesize`, `isstring`, `isbinary`, `group`, `isfromgroup`.

Stream: `add!`, `numgroups`, `group_numblocks`, `group_numbytes`, `group_isclosed`.

Histogram: `numdims`, `numbins`, `totalsize`, `getbin`, `bounds`.

Library info: `libsie_version`.

## Limitations

The C ABI exposed by `libsie_jll` (v0.3) now includes writer functions, however they are low level functions geared for appending blocks to a file stream, or removing channels from a file ect. — substantial work would have to be done to support writing a file from scratch, including writing the xml headers and decoders from scratch. Since the initial purpouse of this library is simply to be able to extract data from this arcane format, this functionality will remain unimplemented.

## Versioning

This is a major rewrite (v0.3). Earlier `0.x` versions of `SomatSIE.jl` parsed SIE files in pure Julia and returned a nested `Dict` from `parseSIE(path)`. That API is gone — use `read(open(SieFile, path) do f ... end, dim)` (or the explicit form) and walk the `file → channel → dimension` tree.

## License

MIT, matching the original project. The underlying `libsie-z` library is LGPL 2.1.
