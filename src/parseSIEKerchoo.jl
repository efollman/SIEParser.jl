#=
    IMPORTANT: Time series SIE only! also may break, no promises
    Optimized script to parse SIE file data, still work in progress.

    The parsing speed is pretty good now, however there are a lot of assumptions that only allow this
    to be used with Time Series data, also if unexpected encodings show up, it may break anyways.
    So far it works with every Time series SIE I've collected.

    Input: SIE filepath e.g. dir/datafiles/mysiefile.sie

    Output: Dictionary indexed by channel number, contains tags, data, dimension info ect in nested dictionaries.
    (tree structure subject to change, trying to generalize to SIE tag structure more in future)
=#

function parseSIE(siepath::String)
    sieData = parseSIEfull(siepath)

    sieData2::Dict{String,Dict{String,Any}} = Dict()

    for key in keys(sieData)
        nkey = sieData[key]["name"]
        sieData2[nkey] = Dict()
        sieData2[nkey]["id"] =  sieData[key]["id"]
        sieData2[nkey]["time"] = sieData[key]["data"][1]
        sieData2[nkey]["data"] = sieData[key]["data"][2]
        if haskey(sieData[key]["chtags"],"core:sample_rate")
            sieData2[nkey]["sr"] = parse(Float64,sieData[key]["chtags"]["core:sample_rate"])
        else
            sieData2[nkey]["sr"] = NaN
        end
        if haskey(sieData[key],"dataType")
            sieData2[nkey]["datatype"] = sieData[key]["dataType"]
        else
            sieData2[nkey]["datatype"] = ""
        end
        if haskey(sieData[key],"sampleN")
            sieData2[nkey]["sampleN"] = sieData[key]["sampleN"]
        else
            sieData2[nkey]["sampleN"] = NaN
        end
        if haskey(sieData[key],"sample_rate")
            sieData2[nkey]["timelabel"] = sieData[key]["dimtags"][1]["core:label"]
        else
            sieData2[nkey]["timelabel"] = ""
        end
        if haskey(sieData[key]["dimtags"][1],"core:units")
            sieData2[nkey]["timeunits"] = sieData[key]["dimtags"][1]["core:units"]
        else
            sieData2[nkey]["timeunits"] = ""
        end
        if haskey(sieData[key]["dimtags"][2],"core:label")
            sieData2[nkey]["label"] = sieData[key]["dimtags"][2]["core:label"]
        else
            sieData2[nkey]["label"] = ""
        end
        if haskey(sieData[key]["chtags"],"core:units")
            sieData2[nkey]["units"] = sieData[key]["dimtags"][2]["core:units"]
        else
            sieData2[nkey]["units"] = ""
        end
        if haskey(sieData[key]["chtags"],"core:description")
            sieData2[nkey]["description"] = sieData[key]["chtags"]["core:description"]
        else
            sieData2[nkey]["description"] = ""
        end
        if haskey(sieData[key]["chtags"],"somat:physical_range_min") && haskey(sieData[key]["chtags"],"somat:physical_range_max")
            sieData2[nkey]["range"] = (parse(Float64,sieData[key]["chtags"]["somat:physical_range_min"]),parse(Float64,sieData[key]["chtags"]["somat:physical_range_max"]))
        else
            sieData2[nkey]["range"] = (NaN,NaN)
        end
        if haskey(sieData[key]["chtags"],"somat:electrical_units")
            sieData2[nkey]["eunits"] = (sieData[key]["chtags"]["somat:electrical_units"])
        else
            sieData2[nkey]["eunits"] = ""
        end
        if haskey(sieData[key]["chtags"],"somat:electrical_range_min") && haskey(sieData[key]["chtags"],"somat:electrical_range_max")
            sieData2[nkey]["erange"] = (parse(Float64, sieData[key]["chtags"]["somat:electrical_range_min"]),parse(Float64, sieData[key]["chtags"]["somat:electrical_range_max"]))
        else
            sieData2[nkey]["erange"] = (NaN,NaN)
        end
        if haskey(sieData[key]["chtags"],"somat:digital_filter_attenuation_frequency")
            sieData2[nkey]["filtfreq"] = parse(Float64, sieData[key]["chtags"]["somat:digital_filter_attenuation_frequency"])
        else
            sieData2[nkey]["filtfreq"] = NaN
        end
        if haskey(sieData[key]["chtags"],"somat:digital_filter_type")
            sieData2[nkey]["filttype"] = sieData[key]["chtags"]["somat:digital_filter_type"]
        else
            sieData2[nkey]["filttype"] = ""
        end
    end
    return sieData2
end

function parseSIEfull(siepath::String)
    open(siepath,"r") do io 
            offset::Vector{UInt32} = [];
            group::Vector{UInt32} = [];
            syncword::Vector{UInt32} = [];
            xmlData::Vector{String} = [];

            i::UInt = 1;

            while !eof(io)
                push!(offset, ntoh(read(io,UInt32)));

                push!(group, ntoh(read(io,UInt32)));

                push!(syncword, ntoh(read(io,UInt32)));
                if syncword[i] != 0x51EDA7A0
                    @warn "bad syncword"
                end
                
                if group[i] == 0
                    rawString::Vector{UInt8} = [];
                    for o = 1:offset[i]-20
                        push!(rawString,read(io,UInt8))
                    end
                    push!(xmlData, String(rawString))
                end

                seek(io,sum(offset));
                i += 1;
            end
            xmlString = join(xmlData)*"</sie>";
            xmlDoc = parsexml(xmlString)
            xmlNodes = elements(xmlDoc.root)
            
            #=
            counterT::Type = Dict{String, UInt64}
            tagT::Type = Dict{String, String}
            indT::Type = Dict{String, UInt32}
            valT::Type = Dict{String, Union{Int64,Float64,UInt64}}
            dimT::Type = Dict{UInt32, Union{tagT,indT,valT}}
            chT::Type = Dict{Union{Dict{String,tagT},indT,dimT,valT}}
            =#
        
            chD::Dict{UInt32,Any} = Dict()
            grouptoch::Dict{UInt32,UInt32} = Dict()


            for i in eachindex(xmlNodes)
                if xmlNodes[i].name == "ch"
                    chindex::UInt32 = parse(UInt,xmlNodes[i]["id"])+1;
                    groupindex::UInt32 = parse(UInt,xmlNodes[i]["group"]);
                    grouptoch[groupindex] = chindex;
                    test::UInt32 = parse(UInt,xmlNodes[i]["test"])+1;
                    name::String = xmlNodes[i]["name"]
                    counter::UInt = 1;

                    chD[chindex] = Dict()

                    chD[chindex]["id"] = chindex;
                    chD[chindex]["test"] = test;
                    chD[chindex]["name"] = name;
                    chD[chindex]["counter"] = counter;

                    chD[chindex]["chtags"]= Dict();
                    chD[chindex]["dimtags"] = Dict();
                    chD[chindex]["data"] = Dict();

                    chNodes = elements(xmlNodes[i])
                    
                    for j in eachindex(chNodes)
                        if chNodes[j].name == "tag"     
                            chD[chindex]["chtags"][chNodes[j]["id"]] = chNodes[j].content;
                        elseif chNodes[j].name == "dim"
                            dimindex::UInt32 = parse(UInt32, chNodes[j]["index"])+1;
                            chD[chindex]["dimtags"][dimindex] = Dict();
                            dimNodes = elements(chNodes[j])
                            for k in eachindex(dimNodes)
                                if dimNodes[k].name == "tag"
                                    dimtagname::String = dimNodes[k]["id"]
                                    chD[chindex]["dimtags"][dimindex][dimtagname] = dimNodes[k].content
                                elseif dimNodes[k].name == "xform"
                                    chD[chindex]["dimtags"][dimindex]["scale"] = parse(Float64,dimNodes[k]["scale"])
                                    chD[chindex]["dimtags"][dimindex]["offset"] = parse(Float64,dimNodes[k]["offset"])
                                end 
                            end
                        end
                    end
                elseif xmlNodes[i].name == "test"
                    if elements(xmlNodes[i])[1].name == "channel"
                        sampleNodes = elements(xmlNodes[i])
                        for l in eachindex(sampleNodes)
                            channelindex::UInt32 = parse(UInt32,sampleNodes[l]["id"])+1;
                            chD[channelindex]["sampleN"] = parse(UInt64,elements(sampleNodes[l])[1].content)
                        end
                    end
                end
            end
            
            for i in eachindex(chD)

                if chD[i]["chtags"]["somat:datamode_type"] != "time_history"
                    error("Data not time series!")
                end
                dataType::Type = Float32
                if chD[i]["chtags"]["somat:data_format"] == "float"
                    if chD[i]["chtags"]["somat:data_bits"] == "32"
                        dataType = Float32
                    elseif chD[i]["chtags"]["somat:data_bits"] == "64"
                        dataType = Float64
                    end
                else
                    error("DataType unknown")
                end
                sampleN::UInt64 = chD[i]["sampleN"]
                timeScale::Float64 = chD[i]["dimtags"][1]["scale"]
                v1::LinRange{Float64, Int64} = LinRange(0, ((sampleN-1)*(timeScale)), sampleN)
                v2::Vector{dataType} = Vector{dataType}(undef,sampleN)
                chD[i]["data"][1] = v1;
                chD[i]["data"][2] = v2;
                chD[i]["dataType"] = dataType;

            end
            
            #groupSet = Set(group)
            #groupSet = collect(groupSet)
            #Threads.@threads for 
            #seti in eachindex(groupSet)
                #setN = groupSet[seti]
                #if setN >= 100
                    for i in eachindex(group)
                        #if group[i] == setN
                        if group[i] >= 100
                            chid::UInt32 = grouptoch[group[i]]
                            seek(io,sum(offset[1:i-1]))
                            bitVec::Vector{UInt8} = Vector{UInt8}(undef,(offset[i]-(4*2)))
                            
                            for k = 1:(offset[i]-(4*2))
                                bitVec[k] = read(io, UInt8)
                            end

                            checksum::UInt32 = ntoh(read(io,UInt32))
                            calc = crc32(bitVec)
                            if (checksum != calc) && (checksum != 0)
                                @warn "Checksum doesnt match"
                            end
                            
                            bvi::UInt = 12
                            timestart::Int64 = reinterpret(Int64,bitVec[bvi+1:bvi+8])[1];
                            bvi += 8 #hardcoded for Int64 data in time scale vector
                            if !isapprox(timestart*chD[chid]["dimtags"][1]["scale"], chD[chid]["data"][1][chD[chid]["counter"]])
                                @warn "LinRange not matching time index in SIE"
                            end

                            v2Blocklength::UInt = (length(bitVec)-bvi)/sizeof(chD[chid]["dataType"])
                            chD[chid]["data"][2][chD[chid]["counter"]:chD[chid]["counter"]+v2Blocklength-1] = reinterpret(chD[chid]["dataType"],bitVec[bvi+1:end])[1:end]
                            chD[chid]["counter"] += v2Blocklength
                                
                        end
                    end
                #end
           #end
            return chD;
    end
end


function crc32(data::Vector{UInt8})
    crc = 0xffffffff
    table = zeros(UInt32, 256)
    for i in 0:255
        tmp = UInt32(i)
        for j in 0:7
            if (tmp & 1) == 1
                tmp = (tmp >> 1) ⊻ 0xedb88320
            else
                tmp >>= 1
            end
        end
        table[i + 1] = tmp
    end
    for byte in data
        idx = ((crc & 0xff) ⊻ UInt32(byte)) + 1
        crc = (crc >> 8) ⊻ table[idx]
    end
    crc ⊻ 0xffffffff
end

#ch = sieparsek("$(@__DIR__)/../SIE/Sensor 2 of 11 - FAILURE.sie")