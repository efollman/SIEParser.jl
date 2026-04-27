# Tags:
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
