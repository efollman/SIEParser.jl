function parseDecoderAsExpr(node::EzXML.Node)
    #decExpr::
    vType::Dict{String,DataType} = Dict()
    vStrVec::Vector{String} = []

    function sieRead(n,inloop::Bool)
        if haskey(n,"bits")
            byteL = parseExpr(UInt,n["bits"]) ÷ 8
        elseif haskey(n, "octets")
            byteL = parseExpr(UInt,n["octets"])
        else
            @error "decoder error read has no bits/octets field"
        end

        if haskey(n,"endian")
            if n["endian"] == "big"
            endq = quote reverse!(readBuff) end
            else
                endq = quote end
            end
        else
            endq = quote end
        end

        
        if haskey(n,"value")
            #assertValue = parseExpr()
        end

        readTypeS = n["type"]

        if readTypeS == "raw"
            readType = Vector{UInt8}
        else
            if readTypeS == "uint"
                readTypeS = "UInt"
            end
            readTypeS = uppercasefirst(readTypeS)*string(byteL*8)
            readType = getfield(Base,Symbol(readTypeS))

        end

        

        if haskey(n,"var")
            var = n["var"]
            if var[1] == 'v' && !(var in vStrVec) #lazy check (check if after v numeric as well?)
                push!(vStrVec,var)
            end
        else
            @error "No var keyword in read op in decoder"
        end

        if !haskey(vType,var)
            vType[var] = readType
        end

        if readType == Vector{UInt8}
            typeq = quote end
        else
            typeq = quote readBuff = reinterpret($readType,readBuff)[] end
        end
        
        if inloop
            bq = quote
                if pointer + $byteL - 1 > length(bin) || pointer < 1
                    breakall = true
                    break
                end
            end
        else
            bq = quote
                if pointer + $byteL - 1 > length(bin) || pointer < 1
                    breakall = true
                end
            end
        end
        

        qb = quote
            $bq
            readBuff = bin[pointer:pointer+$byteL-1]
            $endq
            $typeq
            pointer += $byteL
            $(Symbol("decVar"*n["var"])) = readBuff
            #isUpdated[$(n["var"])] = true
        end

        return qb
    end
    function sieiIf(n)
        @error "If operator in decoder is not implemented"
    end
    function sieSample(n)
        q = quote end
            for str in vStrVec
                q = quote
                    $q
                    push!(dimD[$(QuoteNode(Symbol(str)))], $(Symbol("decVar"*str)))
                end
            end
        return q
    end
    function sieSeek(n)
        if haskey(n,"from")
            if n["from"] == "current"
            else
                @error "Decoder error seek from anything other than current is not implemented"
            end
        end

        if haskey(n,"offset")
            q = quote pointer += $(parseExpr(Int,n["offset"])) end
        else
            @error "Seek in decoder does not have offset tag"
        end

        return q
    end
    function sieSet(n)
        @error "Decode set operation is not implemented"
    end

    function sieLoop(n)
        q = quote end
        for nodeL in elements(n)
            q = quote 
                $q 
                $(doNode(nodeL,true))
            end
        end

        q = quote
            while true
                $q
                if breakall == true
                    break
                end
            end
        end

        return q
          
        
    end

    function parseExpr(Type, string)
        if string[1] == '{' #lazy check

            string = string[2:end-1]


            dollarLoc = 0
            i = 1
            while i <= length(string)
                if string[i] == '$'
                    while true
                        i+=1
                        if i == length(string)
                            string = string * "\"]"
                            break
                        elseif !isletter(string[i])
                            string = string[1:i-1] * "" * string[i:end]
                            break
                        end

                    end
                end
                i += 1
            end

            string = replace(string, "\$" => "decVar")

            #string = "function decFunc$(hash(string))(vars) $string end"

            exprF = Meta.parse(string) #still slightly stinky but better
            
            return quote $exprF end




        else
            return parse(Type, string)
        end
    end
    

    function doNode(nodeD,isloop::Bool)
        if nodeD.name == "read"
            return sieRead(nodeD,isloop)
        elseif nodeD.name == "if"
            return sieIf(nodeD)
        elseif nodeD.name == "sample"
            return sieSample(nodeD)
        elseif nodeD.name == "seek"
            return sieSeek(nodeD)
        elseif nodeD.name == "set"
            return sieSet(nodeD)
        elseif nodeD.name == "loop"
            return sieLoop(nodeD)
        end
    end

    decoderq = quote end

    for nodeFor in elements(node)
        decoderq = quote
            $decoderq
            $(doNode(nodeFor,false))
        end
    end


    decoderHash = hash(decoderq)
    funcName = Symbol("decoder$decoderHash")

    decoderq = quote
        function $funcName(bin,dimD)
            pointer = 1

            #vars::Dict{String,Any} = Dict()
            #isUpdated::Dict{String,Bool} = Dict()
            breakall = false

            $decoderq

            return dimD
        end
    end
    
    return decoderq, vType
end