include("parseBinBlobTags.jl")
include("decoder.jl")

function parseSIE(siepath::String)
    xmlS, binD = parseSIEraw(siepath)

    xmlDoc = parsexml(xmlS)
    nodes = elements(xmlDoc.root)

    rawVoD, sieD = decodeRaw(nodes,binD)

    sieD = combineRawAndClean(sieD,rawVoD) #Not completely finished

    return sieD
    
end

function recurTags!(dict::Dict,chNode::EzXML.Node)
    for n in elements(chNode)
        if n.name == "tag"
            
            dict[attributes(n)[1].content] = mytryparse(n.content)

        elseif n.name == "dim"
            dict["dim$(n["index"])"] = Dict()
            recurTags!(dict["dim$(n["index"])"],n)
        else
            dict[n.name] = Dict()
            for a in attributes(n)
                dict[n.name][a.name] = mytryparse(a.content)
            end
        end
    end
    return dict
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

function decodeRaw(nodes,binD)
    sieD::Dict = Dict()
    decoderD::Dict = Dict()

    for n in nodes
        if n.name == "ch"
            name = n["name"]
            sieD[name] = Dict()
            sieD[name]["tags"] = Dict()
            for a in attributes(n)
                sieD[name]["tags"][a.name] = mytryparse(a.content)
            end
            
            recurTags!(sieD[name]["tags"],n)
        elseif n.name == "decoder"
            decoderD[mytryparse(n["id"])] = n
        end
    end

    groupToName::Dict = Dict()

    for key in keys(sieD)
        groupToName[sieD[key]["tags"]["group"]] = sieD[key]["tags"]["name"]
    end

    decodeData::Dict = Dict()
    evalD::Dict = Dict()
    parsedRaw::Dict{String,Vector{Dict}} = Dict()
    for key in keys(decoderD)
        evalD[key] = eval(parseDecoderAsExpr(decoderD[key]))
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

        outV = []

        for bin in binD[key]
            push!(outV, invokelatest(evalD[decID],bin))
        end

        parsedRaw[chName] = outV

    end
    return parsedRaw, sieD
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
            sieD[key][dim] = []
        end

        for i in parsedRaw[key]
            for dim in dims
                sieD[key][dim] = [sieD[key][dim];i[dim]]
            end
        end

        for dim in dims
            
            if haskey(sieD[key]["tags"]["dim$(dim[2:end])"],"xform")
                if haskey(sieD[key]["tags"]["dim$(dim[2:end])"]["xform"],"scale")
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
                sieD[key]["v0"] = start:(1/sr):(len-1+start)*(1/sr)
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