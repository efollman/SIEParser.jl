# Output:
"""
    Output

A single decoded data block produced by a [`Spigot`](@ref). Owned by the
spigot — invalidated by the next `read`/`iterate` on that spigot.

Use [`numrows`](@ref), [`numdims`](@ref), [`block`](@ref), [`coltype`](@ref),
and [`getfloat64`](@ref) to read individual samples. The vector-like
accessors on [`Dimension`](@ref) (`dim[i]`, `dim[a:b]`, `collect(dim)`)
use the bulk libsie range getters internally and are the preferred way to
read channel data.
"""
struct Output
    handle::Ptr{Cvoid}
    parent::Any  # keeps Spigot alive (and thus the data buffer)
end

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

Base.size(o::Output) = (numrows(o), numdims(o))
Base.show(io::IO, o::Output) = print(io,
    "Output(block=", block(o), ", rows=", numrows(o), ", dims=", numdims(o), ")")
