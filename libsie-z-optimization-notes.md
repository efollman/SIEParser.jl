# libsie-z optimization opportunities

Notes captured while optimizing the `fuseMeasurements.jl` pipeline. Everything
here is about the **C library** (`libsie-z`, shipped via `libsie_jll`). The
Julia-side optimizations in `SomatSIE.jl` (`perf/bulk-read`) and `SIETools.jl`
(`perf/cheap-timevec`) are work-arounds for the missing C APIs described below.

> **Status (2026-04-23):** Item (1) — bulk column getter — is **implemented**
> in this repository. New exports: `sie_output_get_float64_range` and
> `sie_output_get_raw_range` (see [include/sie.h](include/sie.h),
> [src/c_api.zig](src/c_api.zig), [src/output.zig](src/output.zig)). Items
> (2) and (3) are unchanged; see status notes inline below.
>
> **SomatSIE.jl status (2026-04-23):** The Julia bindings now consume the
> bulk-range API. New low-level `ccall` wrappers
> `LibSIE.sie_output_get_float64_range` / `LibSIE.sie_output_get_raw_range`
> live in [src/ccalls.jl](src/ccalls.jl), and the high-level hot paths in
> [src/api.jl](src/api.jl) (`Base.read(::SieFile, ::Dimension)`,
> `Base.read!(::SieFile, ::Dimension, ::AbstractVector{Float64})`, and
> `Base.Matrix(::Output)`) now issue one `ccall` per block instead of one
> per sample. The per-sample `Ref{Cdouble}` / `unsafe_convert` dance is
> gone. `Project.toml` requires `libsie_jll = "0.3.2"`
**UNTESTED:** the rebuilt `libsie_jll@0.3.2` is not
> yet published, so this code path has not been exercised against a real
> shared library — the bindings will fail to load until that JLL is
> available. Once it lands, run `Pkg.test("SomatSIE")` and verify the
> bulk-read path against the existing test corpus.

Measured state as of 2026-04-23, all 16 SIE files, 3 channels each:

| Stage                                                              | time   | allocs    |
| ------------------------------------------------------------------ | ------ | --------- |
| Upstream `SomatSIE@exp` + `SIETools@exp3` (baseline)               | 4.05 s | 1.97 GiB  |
| + `SomatSIE` `perf/bulk-read` (hoisted `Ref`, `read!`, `numrows`)  | —      | —         |
| + `SIETools` `perf/cheap-timevec` (`timevec` via `numrows(f,ch)`)  | 2.61 s | 1.01 GiB  |
| + `ChartChannel.t::AbstractVector` (keeps `LinRange`, skips collect) | 2.56 s | 766 MiB   |

Net Julia-side win: **~1.6× faster, ~2.6× fewer bytes**. The remaining ~2.5 s
is dominated by **one C call per sample** through `sie_output_get_float64`.

---

## 1. Bulk column getter — the one that matters

> **Status: IMPLEMENTED.** See `sie_output_get_float64_range` /
> `sie_output_get_raw_range` in [include/sie.h](include/sie.h),
> exports in [src/c_api.zig](src/c_api.zig), and the underlying
> `Output.getFloat64Range` / `Output.getRawRange` in
> [src/output.zig](src/output.zig). Tests live alongside in
> [src/output.zig](src/output.zig) (`output getFloat64Range bulk copy`,
> `output getRawRange bulk fetch`).

### Problem

Reading a channel's value dimension currently costs **one C call per sample**:

```c
sie_status_t sie_output_get_float64(sie_output_t*, size_t dim, size_t row, double* out);
```

For a 500k-sample channel × 3 channels × 16 files that is ~10^7–10^8 Julia→C
crossings. Each ccall on Windows is ~10–30 ns of pure overhead (dlsym
dispatch, argument marshalling, status check) even before any real work
happens inside the library. That alone puts a hard floor of ~1–2 s on the
pipeline and matches what we measure.

### Proposed API

```c
/* Fill `out[0..count-1]` with `count` consecutive rows of dim `dim`
 * starting at `start_row`. `*out_written` receives the number of rows
 * actually written (may be less than `count` at end of stream). */
sie_status_t sie_output_get_float64_range(
    sie_output_t* o,
    size_t        dim,
    size_t        start_row,
    size_t        count,
    double*       out,
    size_t*       out_written);

/* Symmetric for the raw/bytes path. */
sie_status_t sie_output_get_raw_range(
    sie_output_t* o,
    size_t        dim,
    size_t        start_row,
    size_t        count,
    /* ... appropriate byte/offset/length layout ... */);
```

### Shipped API

The actual exported signatures (see [include/sie.h](include/sie.h)):

```c
int sie_output_get_float64_range(sie_Output *handle, size_t dim,
                                 size_t start_row, size_t count,
                                 double *out_buf, size_t *out_written);
int sie_output_get_raw_range(sie_Output *handle, size_t dim,
                             size_t start_row, size_t count,
                             const uint8_t **out_ptrs, uint32_t *out_sizes,
                             size_t *out_written);
```

The raw variant uses parallel `out_ptrs[count]` / `out_sizes[count]` arrays
of borrowed pointers + lengths — same layout as the per-row
`sie_output_get_raw`, just batched. Borrowed pointers remain valid until
the next `sie_spigot_get` call on the owning spigot.

Both functions clamp `count` to the available rows in the output and write
the actual count to `*out_written`. Out-of-range `dim` or wrong dim type
returns `SIE_E_INDEX_OUT_OF_BOUNDS`.

### Why it's such a big win

- **One ccall per block** instead of one per sample. A 500k-sample channel
  with 8k-row blocks drops from 500k ccalls to ~60 — a **~10⁴× reduction** in
  boundary crossings.
- Eliminates per-sample status checking in Julia.
- Inside libsie-z the implementation is almost certainly already `memcpy`
  from a decoded internal buffer; exposing that at the ABI lets the C
  compiler autovectorize the tight loop and removes function-pointer
  indirection for each element.
- Julia side can `read!(file, dim, buf)` directly into a preallocated
  `Vector{Float64}` of `numrows(file,ch)` — zero `Ref{Cdouble}`, zero
  resize-driven Vector growth.

### Expected impact

The 2.5 s / 766 MiB pass should drop into the 0.3–0.6 s range, dominated by
real disk + decompression cost. Allocations should drop by another order of
magnitude because the Vector-growth path disappears entirely.

### Julia-side follow-up once (1) lands

The three `SomatSIE` patches on `perf/bulk-read` (hoisted `Ref`, per-sample
ccall inner loop, `read!`) become irrelevant and should be replaced with a
single per-block `ccall` loop. The code gets simpler.

> **Done in this repo (2026-04-23, untested):** The follow-up is applied.
> [src/api.jl](src/api.jl) `Base.read`, `Base.read!`, and `Base.Matrix` all
> use the per-block range getter; the hoisted `Ref{Cdouble}` /
> `unsafe_convert` scaffolding has been deleted.

### Priority

**High. This is the one.** Everything else in the chain was working around
its absence.

---

## 2. Cheap channel length

> **Status: NOT IMPLEMENTED.** A scan of [src/channel_spigot.zig](src/channel_spigot.zig)
> and [src/group_spigot.zig](src/group_spigot.zig) confirms there is no
> file-level row index — block row counts only become known after
> running the decoder on each block. An O(1) `sie_channel_num_rows`
> would require building a row-count cache during file open (or
> populating it lazily on first walk). Deferred per the original
> "do this if cheap" gate.

### Problem

To find out how many samples a channel has, today the caller must:

1. Attach a spigot.
2. Walk it block by block, calling `sie_output_num_rows(output)` per block.
3. Sum.

That's what `SomatSIE.numrows(file::SieFile, ch::Channel)` does on the
`perf/bulk-read` branch. It's fast enough (~0.7 s / 426 KiB for all 16 files)
but it still does real work and spins up a spigot just to count.

### Proposed API

```c
size_t sie_channel_num_rows(sie_channel_t* ch);
/* or, if different dims can have different lengths: */
size_t sie_channel_dim_num_rows(sie_channel_t* ch, size_t dim);
```

Ideally this reads from a file-level index without walking data.

### Why

`SIETools.timevec` needs only the length + `core:sample_rate` +
`core:start_time` to produce a `LinRange`. With this API the whole
time-axis construction becomes O(1) instead of O(num_blocks).

### Priority

Medium. Nice quality-of-life, and would let us remove the spigot-walking
fallback in `SomatSIE.numrows(file,ch)`. Not as impactful as (1).

---

## 3. Scalar-return variant of the per-sample getter

> **Status: SKIPPED** (as recommended). Now that (1) is shipped, the
> per-sample path is cold and the marginal `Ref{Cdouble}` win is not
> worth the API surface.

### Problem

`sie_output_get_float64` returns via out-pointer, which forces Julia to
allocate a `Ref{Cdouble}`. Even with the `Ref` hoisted out of the loop it
requires `GC.@preserve` + `Base.unsafe_convert` to hand the stable pointer
to the ccall.

### Proposed API

```c
double        sie_output_get_float64_value(sie_output_t*, size_t dim, size_t row);
sie_status_t  sie_output_last_error(sie_output_t*);  /* optional */
```

### Priority

**Skip if (1) lands.** The per-sample path becomes cold once the bulk range
getter exists, so this is marginal. Don't bother.

---

## 4. Things NOT to optimize in libsie-z

- **Threading / concurrent file access** inside libsie-z. The workload is
  N independent files; parallelize at the Julia level with `Threads.@spawn`
  per file in `doTree` (or in a batched `pmap`). No need for the C library
  to grow a thread pool.
- **SIMD for decoding/decompression**. Current profile shows we are
  ccall-bound, not CPU-bound inside the library. Revisit only after (1)
  eliminates the boundary-crossing overhead.
- **Alternate file formats / memory mapping**. Would be a re-architecture,
  not an optimization, and the bulk-getter change captures most of the win
  available from going to mmap anyway (both collapse per-sample cost).

---

## Ordered recommendation

1. ~~`sie_output_get_float64_range` + `sie_output_get_raw_range`~~ — **DONE**
   ([src/c_api.zig](src/c_api.zig), [include/sie.h](include/sie.h)).
2. `sie_channel_num_rows` / `sie_channel_dim_num_rows` — deferred; no
   cheap path exists today (would need a row-count cache built at file
   open).
3. Scalar-return variant — skipped.

Once (1) is shipped in `libsie_jll`, replace the per-sample inner loops in
`SomatSIE.jl` with block-range ccalls and retire the `perf/bulk-read`
workarounds. The `SIETools` `perf/cheap-timevec` change and the
`ChartChannel.t::AbstractVector` change should stay regardless — they are
structural improvements, not workarounds.
