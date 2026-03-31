include("parseBinBlobTags.jl")
include("decoder.jl")

function parseSIE(siepath::String)
    xmlS, binD = parseSIEraw(siepath)

    xmlDoc = parsexml(xmlS)
    

    sieD = decodeRaw(xmlDoc,binD)

    #sieD = combineRawAndClean(sieD,rawVoD) #Not completely finished

    return sieD
    
end

function recurTags!(dict::Dict,decD::Dict,chNode::EzXML.Node)
    for n in elements(chNode)
        if n.name == "test"
            if mytryparse(n["id"]) != 0
                @warn "testid not zero probably need to fix something in sie parser"
                continue
            end
            recurTags!(dict,decD,n)
        elseif n.name == "ch" || n.name == "channel"
            id = mytryparse(n["id"])
            if !haskey(dict,id)
                dict[id] = Dict()
                dict[id]["tags"] = Dict()
            end
            for a in attributes(n)
                if a.name == "test"
                    if mytryparse(a.content) != 0
                        @warn "testid not zero probably need to fix something in sie parser"
                        continue
                    end
                end
                dict[id]["tags"][a.name] = mytryparse(a.content)
            end
            
            recurTags!(dict[id]["tags"],decD,n)
        elseif n.name == "decoder"
            decD[mytryparse(n["id"])] = n
        elseif n.name == "tag"
            
            dict[attributes(n)[1].content] = mytryparse(n.content)

        elseif n.name == "dim"
            dict["dim$(n["index"])"] = Dict()
            recurTags!(dict["dim$(n["index"])"],decD,n)
        else
            dict[n.name] = Dict()
            for a in attributes(n)
                dict[n.name][a.name] = mytryparse(a.content)
            end
        end
    end
    return nothing
end

function mytryparse(val::String)
    out = nothing
    out = tryparse(UInt,val)
    if !isnothing(out) return out end
    out = tryparse(Int,val)
    if !isnothing(out) return out end
    out = tryparse(Float64,val)
    if !isnothing(out) return out end
    return val
end

function decodeRaw(doc,binD)
    sieDN::Dict = Dict()
    sieD::Dict = Dict()
    decoderD::Dict = Dict()

    recurTags!(sieDN,decoderD,doc.root)

    for nkey in keys(sieDN)
        if isa(nkey,Real)
            sieD[sieDN[nkey]["tags"]["name"]] = sieDN[nkey]
        end
    end

    groupToName::Dict = Dict()

    for key in keys(sieD)
        groupToName[sieD[key]["tags"]["group"]] = sieD[key]["tags"]["name"]
    end

    decodeData::Dict = Dict()
    evalD::Dict = Dict()
    typeD::Dict = Dict()
    for key in keys(decoderD)
        expr,typeD[key] = parseDecoderAsExpr(decoderD[key])
        evalD[key] = eval(expr)
    end

    for key in keys(binD)
        chName = groupToName[key]

        for tag in keys(sieD[chName]["tags"])
            if contains(tag,"dim")
                v = "v$(sieD[chName]["tags"][tag]["data"]["v"])"
                decodeData[v] = Dict()
                decodeData[v]["decID"] = sieD[chName]["tags"][tag]["data"]["decoder"]
                if haskey(sieD[chName]["tags"][tag], "xform")
                    decodeData[v]["xform"] = sieD[chName]["tags"][tag]["xform"]
                end

            end
        end

        lastID = 42069
        for key in keys(decodeData)
            if decodeData[key]["decID"] != lastID && lastID != 42069
                @error "different decoders for same channel????"
            end
            lastID = decodeData[key]["decID"]
        end
        decID = lastID

        dimD = Dict()
        for var in keys(typeD[decID])
            if typeD[decID][var] == Vector{UInt8}
                dimD[var] = fill(Vector{UInt8}([]),sieD[chName]["tags"]["SampleCount"])
            else
                dimD[var] = zeros(typeD[decID][var],sieD[chName]["tags"]["SampleCount"])
            end

        end

        samplei = 1

        for bin in binD[key]
            (dimD, samplei) = invokelatest(evalD[decID],bin,dimD,samplei)
        end

        for key in keys(dimD)
            sieD[chName][key] = dimD[key]
        end

    end
    return sieD
end

function combineRawAndClean(sieD,parsedRaw)
    for key in keys(parsedRaw)
        dims = []
        for dimkey in keys(sieD[key]["tags"])
            if contains(dimkey,"dim")
                push!(dims, "v$(sieD[key]["tags"][dimkey]["data"]["v"])")
                
            end
        end
        for dim in dims
            #vecType = typeparse(sieD[key]["tags"]["dim$(dim[2:end])"]["somat:data_format"]) Implement this for proper type pull
            sieD[key][dim] = []
        end

        for i in parsedRaw[key]
            for dim in dims
                vecType = typeof(i[dim])#should probably pull this from tags, will break 
                sieD[key][dim] = vecType([sieD[key][dim];i[dim]])
            end
        end

        for dim in dims
            
            if haskey(sieD[key]["tags"]["dim$(dim[2:end])"],"xform")
                if haskey(sieD[key]["tags"]["dim$(dim[2:end])"]["xform"],"scale")
                    sieD[key][dim] = Vector{Float64}(sieD[key][dim]) # bodge
                    sieD[key][dim] .*= sieD[key]["tags"]["dim$(dim[2:end])"]["xform"]["scale"]
                end
                if haskey(sieD[key]["tags"]["dim$(dim[2:end])"]["xform"],"offset")
                    sieD[key][dim] .+= sieD[key]["tags"]["dim$(dim[2:end])"]["xform"]["offset"]
                end
            end
        end

        #hardcoded Fix could be better (could sample vectors with step?, check if vector is Unit stepable at end, would be inneficient but covers more edge cases)
        #confirmed doesnt handle event slices in sequential, uses tags do define mx + b transform. they just decided it should be implied in TS ¯\_(ツ)_/¯

        if haskey(sieD[key]["tags"],"somat:datamode_type") && haskey(sieD[key]["tags"],"core:sample_rate")
            if sieD[key]["tags"]["somat:datamode_type"] == "time_history" && sieD[key]["tags"]["dim0"]["core:units"] == "Seconds"
                start = sieD[key]["v0"][1]
                sr = sieD[key]["tags"]["core:sample_rate"]
                len = length(sieD[key]["v1"])
                sieD[key]["v0"] = collect(start:(1/sr):(len-1+start)*(1/sr))
            end
        end

        if haskey(sieD[key]["tags"],"somat:datamode_type")
            if sieD[key]["tags"]["somat:datamode_type"] == "time_history"
                for dim in dims
                    if length(sieD[key]["v0"]) != length(sieD[key][dim])
                        @warn "Vector length mismatch in sequential data, check assumptions made in TS decoder fix"
                        println(key)
                    end
                end
            end
        end
    end
    return sieD
end