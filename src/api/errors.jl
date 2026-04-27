# Errors:
"""
    SieError(code, message)

Exception thrown when a libsie call returns a non-zero status code.
"""
struct SieError <: Exception
    code::Int
    message::String
end

Base.showerror(io::IO, e::SieError) =
    print(io, "SieError(", e.code, "): ", e.message)

@inline function _check(rc::Integer)
    rc == L.SIE_OK && return nothing
    throw(SieError(Int(rc), L.sie_status_message(rc)))
end

# Helpers for (ptr, len) string returns:
function _ptrlen_to_string(getter, h)
    pref = Ref{Ptr{UInt8}}(C_NULL)
    nref = Ref{Csize_t}(0)
    getter(h, pref, nref)
    p, n = pref[], Int(nref[])
    (p == C_NULL || n == 0) ? "" : unsafe_string(p, n)
end

function _ptrlen_to_bytes(getter, h)
    pref = Ref{Ptr{UInt8}}(C_NULL)
    nref = Ref{Csize_t}(0)
    getter(h, pref, nref)
    p, n = pref[], Int(nref[])
    (p == C_NULL || n == 0) ? UInt8[] : copy(unsafe_wrap(Array, p, n; own = false))
end

