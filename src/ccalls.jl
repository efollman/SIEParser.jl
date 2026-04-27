# Low-level ccall bindings for libsie's C ABI.
#
# Mirrors include/sie.h from https://github.com/efollman/libsie-z. Only the
# functions actually used by the high-level Julia API in `SomatSIE` are
# bound; the rest of libsie's surface (stream/histogram/seek-by-value,
# secondary lookups, etc.) is intentionally omitted. Add bindings here as
# new high-level features need them.
#
# All functions live in the (unexported) `LibSIE` submodule so user code
# can stay on the high-level Julia API in `SomatSIE`.

module LibSIE

using libsie_jll: libsie

# Status codes:
const SIE_OK                   = Cint(0)
const SIE_E_FILE_NOT_FOUND     = Cint(1)
const SIE_E_PERMISSION_DENIED  = Cint(2)
const SIE_E_FILE_OPEN          = Cint(3)
const SIE_E_FILE_READ          = Cint(4)
const SIE_E_FILE_WRITE         = Cint(5)
const SIE_E_FILE_SEEK          = Cint(6)
const SIE_E_FILE_TRUNCATED     = Cint(7)
const SIE_E_INVALID_FORMAT     = Cint(10)
const SIE_E_INVALID_BLOCK      = Cint(11)
const SIE_E_UNEXPECTED_EOF     = Cint(12)
const SIE_E_CORRUPTED_DATA     = Cint(13)
const SIE_E_INVALID_XML        = Cint(20)
const SIE_E_INVALID_EXPRESSION = Cint(21)
const SIE_E_PARSE              = Cint(22)
const SIE_E_OUT_OF_MEMORY      = Cint(30)
const SIE_E_INVALID_DATA       = Cint(40)
const SIE_E_DIMENSION_MISMATCH = Cint(41)
const SIE_E_INDEX_OUT_OF_BOUNDS = Cint(42)
const SIE_E_NOT_IMPLEMENTED    = Cint(50)
const SIE_E_OPERATION_FAILED   = Cint(51)
const SIE_E_STREAM_ENDED       = Cint(52)
const SIE_E_UNKNOWN            = Cint(99)

# Output dimension types:
const SIE_OUTPUT_NONE    = Cint(0)
const SIE_OUTPUT_FLOAT64 = Cint(1)
const SIE_OUTPUT_RAW     = Cint(2)

# Library info:
sie_status_message(s::Integer) =
    unsafe_string(ccall((:sie_status_message, libsie), Cstring, (Cint,), Cint(s)))

# SieFile:
sie_file_open(path, out) =
    ccall((:sie_file_open, libsie), Cint, (Cstring, Ptr{Ptr{Cvoid}}), path, out)
sie_file_close(h) =
    ccall((:sie_file_close, libsie), Cvoid, (Ptr{Cvoid},), h)

sie_file_num_tests(h) = ccall((:sie_file_num_tests, libsie), Csize_t, (Ptr{Cvoid},), h)
sie_file_num_tags(h)  = ccall((:sie_file_num_tags,  libsie), Csize_t, (Ptr{Cvoid},), h)

sie_file_test(h, i) =
    ccall((:sie_file_test, libsie), Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t), h, Csize_t(i))
sie_file_tag(h, i) =
    ccall((:sie_file_tag,  libsie), Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t), h, Csize_t(i))

# Test:
sie_test_id(h)           = ccall((:sie_test_id,           libsie), UInt32,  (Ptr{Cvoid},), h)
sie_test_num_channels(h) = ccall((:sie_test_num_channels, libsie), Csize_t, (Ptr{Cvoid},), h)
sie_test_num_tags(h)     = ccall((:sie_test_num_tags,     libsie), Csize_t, (Ptr{Cvoid},), h)
sie_test_channel(h, i) =
    ccall((:sie_test_channel, libsie), Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t), h, Csize_t(i))
sie_test_tag(h, i) =
    ccall((:sie_test_tag,     libsie), Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t), h, Csize_t(i))

# Channel:
sie_channel_id(h)       = ccall((:sie_channel_id,       libsie), UInt32,  (Ptr{Cvoid},), h)
sie_channel_num_dims(h) = ccall((:sie_channel_num_dims, libsie), Csize_t, (Ptr{Cvoid},), h)
sie_channel_num_tags(h) = ccall((:sie_channel_num_tags, libsie), Csize_t, (Ptr{Cvoid},), h)
sie_channel_name(h, ptr, len) =
    ccall((:sie_channel_name, libsie), Cvoid, (Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{Csize_t}), h, ptr, len)
sie_channel_dimension(h, i) =
    ccall((:sie_channel_dimension, libsie), Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t), h, Csize_t(i))
sie_channel_tag(h, i) =
    ccall((:sie_channel_tag,       libsie), Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t), h, Csize_t(i))

# Dimension:
sie_dimension_index(h)    = ccall((:sie_dimension_index,    libsie), UInt32,  (Ptr{Cvoid},), h)
sie_dimension_num_tags(h) = ccall((:sie_dimension_num_tags, libsie), Csize_t, (Ptr{Cvoid},), h)
sie_dimension_tag(h, i) =
    ccall((:sie_dimension_tag, libsie), Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t), h, Csize_t(i))

# Tag:
sie_tag_key(h, ptr, len) =
    ccall((:sie_tag_key,   libsie), Cvoid, (Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{Csize_t}), h, ptr, len)
sie_tag_value(h, ptr, len) =
    ccall((:sie_tag_value, libsie), Cvoid, (Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{Csize_t}), h, ptr, len)
sie_tag_is_string(h) = ccall((:sie_tag_is_string, libsie), Cint, (Ptr{Cvoid},), h)

# Spigot:
sie_spigot_attach(file, ch, out) =
    ccall((:sie_spigot_attach, libsie), Cint,
          (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Ptr{Cvoid}}), file, ch, out)
sie_spigot_free(h) = ccall((:sie_spigot_free, libsie), Cvoid, (Ptr{Cvoid},), h)
sie_spigot_get(h, out) =
    ccall((:sie_spigot_get,   libsie), Cint,    (Ptr{Cvoid}, Ptr{Ptr{Cvoid}}), h, out)
sie_spigot_tell(h)       = ccall((:sie_spigot_tell,       libsie), UInt64,  (Ptr{Cvoid},), h)
sie_spigot_reset(h)      = ccall((:sie_spigot_reset,      libsie), Cvoid,   (Ptr{Cvoid},), h)
sie_spigot_num_blocks(h) = ccall((:sie_spigot_num_blocks, libsie), Csize_t, (Ptr{Cvoid},), h)

# Output:
sie_output_num_dims(h) = ccall((:sie_output_num_dims, libsie), Csize_t, (Ptr{Cvoid},), h)
sie_output_num_rows(h) = ccall((:sie_output_num_rows, libsie), Csize_t, (Ptr{Cvoid},), h)
sie_output_block(h)    = ccall((:sie_output_block,    libsie), Csize_t, (Ptr{Cvoid},), h)
sie_output_type(h, dim) =
    ccall((:sie_output_type, libsie), Cint, (Ptr{Cvoid}, Csize_t), h, Csize_t(dim))
sie_output_get_float64(h, dim, row, val) =
    ccall((:sie_output_get_float64, libsie), Cint,
          (Ptr{Cvoid}, Csize_t, Csize_t, Ptr{Cdouble}),
          h, Csize_t(dim), Csize_t(row), val)

# Bulk range getters (libsie-z >= 0.3.2). These collapse the per-sample
# Julia↔C crossing into one call per block. See libsie-z-optimization-notes.md
# item (1) for design notes.
sie_output_get_float64_range(h, dim, start_row, count, out_buf, out_written) =
    ccall((:sie_output_get_float64_range, libsie), Cint,
          (Ptr{Cvoid}, Csize_t, Csize_t, Csize_t, Ptr{Cdouble}, Ptr{Csize_t}),
          h, Csize_t(dim), Csize_t(start_row), Csize_t(count), out_buf, out_written)
sie_output_get_raw_range(h, dim, start_row, count, out_ptrs, out_sizes, out_written) =
    ccall((:sie_output_get_raw_range, libsie), Cint,
          (Ptr{Cvoid}, Csize_t, Csize_t, Csize_t,
           Ptr{Ptr{UInt8}}, Ptr{UInt32}, Ptr{Csize_t}),
          h, Csize_t(dim), Csize_t(start_row), Csize_t(count),
          out_ptrs, out_sizes, out_written)

end # module LibSIE
