# SomatSIE

[![Build Status](https://github.com/efollman/SIEParser.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/efollman/SomatSIE.jl/actions/workflows/CI.yml?query=branch%3Amaster)

This is a WIP parser for Somat SIE files produced by their edaq equipment.

usage:
```julia
parseSIE("path/to/file.sie")
```

The output of this function is a Nested dictionary. The keys being "tags" and "v0","v1",...,"vn" depending on the number of vectors defined in the file. "tags" contains all of the xml tags for that channel found in the file.

Most likely you will be working with basic time series data channes, in this case "v0" is always time and "v1" is data (This is pulled from convention found in the file) this may also be changed to better lables in the future.


known problems:
- I havent seen every type of channel possible so things could break unexpectedly. As far as i know you should always get the raw data vectors read from the file though for the most part.
- currently the entire file is loaded into a dictionary in memory. This may not be ideal for large files or if only some channels or a portion of a channel are desired.
- the part that parses the decoder found in the file heavily uses julia metaprogramming features which I am new too. for the most part it is well defined with quote blocks; however, parsing expressions found in the decoder directly uses meta.parse which could technically allow code injection with untrusted files or something.
- in the decoder parser described above, some of the opperators such as IF and SET are not implemented yet as I havent seen them in a file to be able to test them properly. similarly some options such as seek from start or from end are not implemented. should hopefully throw warning/error messages if these come up.
- Currently the solution for ensuring the time vector steps properly is a bodge, and may not always function properly. (this is due to only one sample for time in every 1000+ sample block in file, i havent found a reliable way to make sure this implies the time vector should be stepped.)
- related to above, m=# b=# linear transforms are sometimes found in other channels (seem to just be implied in basic time series channels), this is also not implemented yet.
- raw type is currently represented as a vector of vectors of UInt8, this might not be the most efficient.
- types defined in the channels are not currently used. types are kept as they are read from the decoder and converted to Float64 if an xform tag is defined.
- the nested Dictionaries in the output are {Any,Any} when it could be simplified to something like {String,Union{<:Real,Vector{UInt8},Itself}} though i havent figured out recursive type definition yet. it is unclear how much benifit this would have
- as the modes are pretty well defined, the "v0" style tags could be auto renamed to "time" "data" ect though this would be a breaking change.
- the base tags could also be represented by symbols such as :time :data  :tags for easier typing. (could maybe pull this from tags, unsure if they are reliably there and consistent)
- commonly needed tags should be exposed as base level tags such as :sr for sample rate. Should be careful with this as removing them would be breaking after they are added
- not sure that a nested dictionary is the right approach. a struct would be nicer but i had problems with memory efficency due to the nature of the information.
- tests need to be improved with a larger variety of files, as well as proper verification they are parsed correctly. Somat offers an edaq emulator which may allow me to generate a variety of files without exposing sensitive information.
- code is pretty messy and unorganized at the moment ¯\\_(ツ)_/¯
