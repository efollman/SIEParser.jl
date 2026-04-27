# SieFile:
"""
    SieFile

An opened SIE file handle. Open one with [`opensie`](@ref) using the
do-block form so the underlying libsie handle is released automatically:

    opensie("myfile.sie") do f
        for t in f.tests, ch in t.channels
            for dim in ch.dims
                println(ch.name, " dim ", dim.id, ": ", collect(dim))
            end
        end
    end
"""
mutable struct SieFile
    handle::Ptr{Cvoid}
    path::String
    # Per-channel cache of decoded blocks + a persistent spigot. Populated
    # lazily on first vector-like access of a `Dimension`. Keyed by the
    # libsie channel handle (stable for the file's lifetime). Type-erased
    # to `Any` because `ChannelCache` is defined further down in this file.
    caches::Dict{Ptr{Cvoid}, Any}

    function SieFile(path::AbstractString)
        out = Ref{Ptr{Cvoid}}(C_NULL)
        _check(L.sie_file_open(String(path), out))
        sf = new(out[], String(path), Dict{Ptr{Cvoid}, Any}())
        finalizer(_finalize_file, sf)
        return sf
    end
end

# Close every cached spigot for `sf` and forget them. Must run BEFORE the
# underlying file handle is freed, because spigots are owned by the file.
function _close_caches!(sf::SieFile)
    isempty(sf.caches) && return nothing
    for (_, cache) in sf.caches
        try
            close(cache.spigot)
        catch
            # Best-effort: don't let a single bad spigot block cleanup.
        end
    end
    empty!(sf.caches)
    return nothing
end

function _finalize_file(sf::SieFile)
    if sf.handle != C_NULL
        _close_caches!(sf)
        L.sie_file_close(sf.handle)
        sf.handle = C_NULL
    end
end

"""
    close(file::SieFile)

Release the underlying libsie file handle. Idempotent. After closing, any
borrowed `Test`/`Channel`/`Tag`/`Dimension` references become invalid.
"""
function Base.close(sf::SieFile)
    if sf.handle != C_NULL
        _close_caches!(sf)
        L.sie_file_close(sf.handle)
        sf.handle = C_NULL
    end
    return nothing
end

Base.isopen(sf::SieFile) = sf.handle != C_NULL

"""
    opensie(f::Function, path)

Open the SIE file at `path`, pass the resulting [`SieFile`](@ref) to `f`,
and close it (releasing the underlying libsie handle) when `f` returns
\u2014 even if it throws. Use it with do-block syntax:

```julia
opensie("myfile.sie") do f
    for t in f.tests, ch in t.channels
        println(ch.name)
    end
end
```
"""
opensie(path::AbstractString) = SieFile(path)

function opensie(f::Function, path::AbstractString)
    sf = SieFile(path)
    try
        return f(sf)
    finally
        close(sf)
    end
end

function _check_open(sf::SieFile)
    sf.handle == C_NULL && error("SieFile is closed")
    return sf.handle
end

_ntests(sf::SieFile) = Int(L.sie_file_num_tests(_check_open(sf)))

function _test(sf::SieFile, i::Integer)
    h = _check_open(sf)
    1 <= i <= _ntests(sf) || throw(BoundsError(sf, i))
    p = L.sie_file_test(h, i - 1)
    p == C_NULL ? throw(BoundsError(sf, i)) : Test(p, sf)
end

_tests(sf::SieFile) = [_test(sf, i) for i in 1:_ntests(sf)]

_tags(sf::SieFile) = (h = _check_open(sf);
    _build_tags(h, Int(L.sie_file_num_tags(h)), L.sie_file_tag))

"""
    findchannel(test, name::AbstractString) -> Channel | nothing

Look up a channel within `test` by its name. Returns `nothing` if no
channel in the test has the requested name. The match is exact
(case-sensitive); if multiple channels share the name, the first one is
returned.
"""
function findchannel(t::Test, chname::AbstractString)
    for c in t.channels
        c.name == chname && return c
    end
    return nothing
end

function Base.getproperty(sf::SieFile, sym::Symbol)
    sym === :tests && return _tests(sf)
    sym === :tags  && return _tags(sf)
    sym === :channels && error(
        "`SieFile` has no `channels` property because channel ids may " *
        "collide between tests. Iterate via `f.tests` instead, e.g. " *
        "[ch for t in f.tests for ch in t.channels].")
    return getfield(sf, sym)
end
Base.propertynames(::SieFile, private::Bool = false) =
    private ? (:tests, :tags, :path, :handle, :caches) : (:tests, :tags, :path)

Base.show(io::IO, sf::SieFile) = print(io,
    "SieFile(", repr(sf.path), isopen(sf) ? "" : ", closed", ")")
