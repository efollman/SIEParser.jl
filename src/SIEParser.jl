module SIEParser

using EzXML

include("parseSIEkachow.jl")
include("OLDparseSIEKerchoo.jl")

export parseSIE
export oldparseSIE

end
