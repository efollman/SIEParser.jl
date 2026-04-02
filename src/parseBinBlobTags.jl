function parseSIEraw(siepath::String)
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
            binDict::Dict{UInt,Vector{Vector{UInt8}}} = Dict()

            for i in eachindex(group)
                if group[i] >= 100
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

                    if !haskey(binDict,group[i])
                        binDict[group[i]] = []
                    end
                    
                    push!(binDict[group[i]],bitVec[13:end])
                        
                end
            end

            return xmlString, binDict;
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