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

opensie("myfile.sie") do f
    println("file: ", length(f.tests), " tests")

    for t in f.tests, ch in t.channels
        for dim in ch.dims
            # A `Dimension` behaves like a 1-D collection of samples:
            #   * `collect(dim)` (alias `dim[:]`) returns the full vector —
            #       `:float64` columns -> Vector{Float64} of engineering values
            #       `:raw`     columns -> Vector{Vector{UInt8}} (e.g. CAN frames)
            #   * `dim[i]` reads a single sample (only the containing block).
            #   * `dim[a:b]` reads a sub-range (only the overlapping blocks).
            data  = collect(dim)
            units = get(dim.tags, "core:units", nothing)
            println("  ", ch.name, " dim ", dim.id,
                    "  ", typeof(data), " len=", length(data),
                    units === nothing ? "" : "  units=" * units)
        end
    end
end
```

`SieFile`, `Test`, `Channel`, and `Dimension` all expose their public
accessors as dot properties — `f.tests`, `f.tags`, `t.id`,
`t.channels`, `t.tags`, `ch.id`, `ch.name`, `ch.dims`, `ch.tags`,
`ch.schema`, `ch.sr`, `dim.id`, `dim.tags`. There are no equivalent
accessor functions; use the property syntax everywhere. The type names
themselves are unexported — qualify them as `SomatSIE.SieFile`,
`SomatSIE.Channel`, etc. — but values returned by `opensie`,
`f.tests`, `t.channels`, and `ch.dims` need no qualification.

For sequential time-series channels, dimension `id == 1` is typically time and
dimension `id == 2` is the engineering value — read each separately and pair
them in your own code.

## Concepts

All types are unexported and accessed as `SomatSIE.<Type>` to avoid name
clashes with `Base.Channel` (Tasks), `Test.Test` (the stdlib testing
module), and any user-defined `SieFile`/`Tags`/`Dimension`. Only the
verbs `opensie` and `findchannel` are exported.

| Type | Purpose |
|------|---------|
| `SomatSIE.SieFile` | An opened SIE file. Owns the underlying handle; `close` it (or use `opensie(path) do f ... end`). |
| `SomatSIE.Test` | A test (acquisition session) within a file. |
| `SomatSIE.Channel` | A data series. |
| `SomatSIE.Dimension` | A single column/axis of a channel. |
| `SomatSIE.Tags` | A `Dict{String, Union{String, Vector{UInt8}}}` of metadata returned by `x.tags`. |
| `SomatSIE.SieError` | Exception type for libsie / file-open errors. |

Tags are plain Julia dicts:

```julia
ts = channel.tags             # Dict{String, Union{String, Vector{UInt8}}}
length(ts)                    # number of tags
for (k, v) in ts; @show k, v; end
ts["core:sample_rate"]        # value (String or Vector{UInt8}); throws KeyError if missing
get(ts, "core:units", nothing)
haskey(ts, "core:schema")
```

## API surface

A full reference — every public type, every dot-property, every
function — lives in [JuliaAPI.md](JuliaAPI.md). The summary below
covers the most common patterns.

Core types (all unexported — qualify with `SomatSIE.`):
`SomatSIE.SieFile`, `SomatSIE.Tags`, `SomatSIE.SieError`,
`SomatSIE.Test`, `SomatSIE.Channel`, `SomatSIE.Dimension`. `Tags` is a
type alias for `Dict{String, Union{String, Vector{UInt8}}}`.

Opening / reading: `opensie(path) do f ... end` to open a file (the
do-block guarantees the handle is released). Each `Dimension` behaves
like a 1-D collection of samples: `dim[i]` reads a single sample (only
the containing block is fetched), `dim[a:b]` reads a range (only the
overlapping blocks are fetched), and `collect(dim)` (also `dim[:]`)
materializes the entire dimension into a typed `Vector{Float64}` (or
`Vector{Vector{UInt8}}` for raw columns). Internally these use libsie's
bulk per-block getters — one `ccall` per block, not per sample.

Navigation: dot-property accessors `f.tests`, `t.channels`,
`ch.dims`, `x.tags`, plus `findchannel(test, name)`. Channels
live under tests — `f.channels` raises an error because channel ids
may collide between tests; iterate with
`for t in f.tests, ch in t.channels`. Use `length(f.tests)`,
`length(t.channels)`, etc. for counts; index the returned `Vector`
directly for positional access.

Identity: `x.id`; channels also have `ch.name`. All `id` properties
(`t.id`, `ch.id`, `dim.id`) are **1-based** — unlike libsie's underlying
0-based convention. For `dim.id`, 1 is typically time and 2 is value on
sequential time-series channels.

Channel convenience accessors: `ch.schema` returns the `core:schema`
tag (or `nothing`), and `ch.sr` returns the `core:sample_rate` tag
parsed as a `UInt` (falling back to `Float64`, or `nothing` if unset
or unparseable). Both are shorthands over `ch.tags`.

> Spigot and Output are kept internal (`SomatSIE.spigot`,
> `SomatSIE.Output`) so the public surface stays small. Prefer
> `dim[i]` / `dim[a:b]` / `collect(dim)`.

## Caching vs. materializing — when to use which

Every libsie-backed `Dimension` reads through a per-`Channel` block
cache: a persistent spigot is opened on first access and reused, decoded
blocks are memoized in a small LRU keyed by `(block_idx, dim_id)`, and a
cumulative-row offset table lets `dim[i]` and `dim[a:b]` jump straight
to the containing block. The result is that **partial / random access
on large files is cheap** — only the blocks you touch are decoded, and
re-touching the same neighborhood costs nothing. This is the right tool
for browsing, previewing, plotting a slice, or extracting a few channels
out of a multi-gigabyte file.

If you intend to do **substantial work on a dimension's data**
(filtering, FFTs, statistics, repeated full passes), pull the data out
of the cache once and operate on a plain `Vector` instead. Each cached
read still pays a dictionary lookup, an LRU touch, and bounds checks
per call; a `Vector` does none of that and inlines into tight loops.
Two equivalent escape hatches:

```julia
opensie("file.sie") do f
    ch = first(first(f.tests).channels)

    # 1. Per dimension — cheapest, returns a typed Vector{Float64}
    #    (or Vector{Vector{UInt8}} for raw columns).
    v = collect(ch.dims[2])
    # ... heavy work on `v` ...

    # 2. Whole tree at once — detaches everything from the file so you
    #    can keep working after the do-block returns.
    snapshot = sieDetach(f)
    # or
    testSnap = sieDetach(f.tests[1])
    # or
    chSnap = sieDetach(f.tests[1].channels[1])
    # or
    dimSnap = sieDetach(f.tests[1].channels[1].dims[1])
    # this is designed so only the information that is really needed can be loaded into memory
    # avoiding unnecessary work.
end
# `snapshot` is a Vector{VectorTest}; the file handle is gone but
# every dim, channel, and test is still fully usable.
```

Rule of thumb: **small files or whole-channel processing → `sieDetach`
/ `collect(dim)` once, then forget the file.** **Large files or sparse
access → keep the `SieFile` open and let the cache do its job.** Both
paths return identical values; the choice is purely about per-access
overhead.

## Plotting and DataFrames

`Dimension` is a proper `AbstractVector{T}` (with `T` probed at construction:
`Float64` for engineering values, `Vector{UInt8}` for raw payloads), so it
plugs into the rest of the ecosystem with no extra glue:

```julia
using SomatSIE, DataFrames, CairoMakie
opensie("file.sie") do f
    ch = first(first(f.tests).channels)
    df = DataFrame(:t => ch.dims[1], :v => ch.dims[2])   # auto-collected
    lines(ch.dims[1], ch.dims[2])                        # time vs. value
    scatter(ch.dims[2])
end
```

Indexing (`dim[i]`, `dim[a:b]`) still goes through the per-channel block
cache, so reading is incremental — only the blocks you touch are decoded.

## Building tests, channels, and dimensions in memory

`Test`, `Channel`, and `Dimension` are abstract types with two concrete
subtypes each: a libsie-backed variant returned when reading a file, and
a vector-backed variant you can construct from edited or synthetic data.
Anywhere a function is typed `f(::SomatSIE.Test)`, `f(::SomatSIE.Channel)`,
or `g(::SomatSIE.Dimension)`, either variant works.

```julia
using SomatSIE
using SomatSIE: Test, Channel, Dimension, Tags

# Build dimensions from any AbstractVector. Element type is inferred.
t = Dimension(0.0:0.01:1.0;       id = 1, tags = Tags("core:units" => "s"))
v = Dimension(sin.(2π .* (0:100) ./ 100); id = 2, tags = Tags("core:units" => "V"))

# Bundle them into a channel.
ch = Channel("synthetic_sine", [t, v];
             id   = 1,
             tags = Tags("core:sample_rate" => "100",
                         "core:schema"      => "timhis"))

ch.name              # "synthetic_sine"
ch.sr                # UInt(100)
ch.dims[2][1:5]      # works just like a libsie-backed dim
collect(ch.dims[1])  # returns a Vector{Float64}

# Bundle channels into a test.
test = Test([ch]; id = 1, tags = Tags("operator" => "ef"))
findchannel(test, "synthetic_sine") === ch   # true
```

This makes it easy to feed downsampled, filtered, or otherwise edited
data into existing pipelines without changing their type signatures.

### Snapshotting a file with `sieDetach`

`sieDetach` materializes any libsie-backed value into its in-memory
`Vector*` variant, recursively. The result is fully detached from the
source `SieFile` and remains valid after the file is closed:

```julia
snapshot = opensie("file.sie") do f
    sieDetach(f)        # Vector{VectorTest}
end
# `snapshot` is still usable here; the file handle is gone.

# Per-level: works on a Test, Channel, or Dimension too.
opensie("file.sie") do f
    vt = sieDetach(first(f.tests))             # VectorTest
    vc = sieDetach(first(first(f.tests).channels))  # VectorChannel
    vd = sieDetach(first(first(first(f.tests).channels).dims))  # VectorDimension
end
```

`sieDetach` is idempotent and zero-copy on already-in-memory values \u2014
calling it on a `VectorChannel` returns the same object (`===`).

## Limitations

The C ABI exposed by `libsie_jll` (v0.3) now includes writer functions, however they are low-level functions geared toward appending blocks to an existing file stream or removing channels — substantial work would be required to support writing a file from scratch, including emitting the XML headers and decoders. Since the initial purpose of this library is simply to extract data from this arcane format, that functionality remains unimplemented.

## Versioning

This is a major rewrite (v0.3). Earlier `0.x` versions of `SomatSIE.jl` parsed SIE files in pure Julia and returned a nested `Dict` from `parseSIE(path)`. That API is gone — use `opensie(path) do f ... end` and walk the `file → channel → dimension` tree, indexing each `dim` directly (`dim[i]`, `dim[a:b]`, `collect(dim)`) to materialize data.

## License

MIT, matching the original project. The underlying `libsie-z` library is LGPL 2.1.
