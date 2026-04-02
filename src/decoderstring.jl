#=
<decoder id="2">
 <loop>
  <read var="v0" bits="64" type="int" endian="little"/>
  <seek from="current" offset="12"/>
  <read var="ff" bits="8" type="uint" endian="big"/>
  <seek from="current" offset="-13"/>
  <read var="v1" octets="{4 + ($ff &amp; 15)}" type="raw"/>
  <seek from="current" offset="{9 - ($ff &amp; 15)}"/>
  <sample/>
 </loop>
</decoder>

<ch test="0" id="0" name="raw_can1_edaqxr_5508cc" group="100">
 <tag id="core:uuid">c4d4a2db-588d-4738-9d73-e2fd783fcbf2</tag>
 <tag id="data_type">message_can</tag>
 <tag id="somat:data_format">int</tag>
 <tag id="somat:message_format">CAN</tag>
 <tag id="core:description">Raw CAN messages</tag>
 <tag id="somat:input_channel">raw_can1_edaqxr_5508cc</tag>
 <tag id="core:sample_rate">0</tag>
 <tag id="somat:datamode_name">__dm</tag>
 <tag id="somat:datamode_type">message_log</tag>
 <tag id="somat:connector">@can1.edaqxr_lite-560238</tag>
 <tag id="somat:data_bits">1</tag>
 <tag id="core:schema">somat:message</tag>
 <tag id="somat:connection">ecpuxr_lite-560238:can1</tag>
 <tag id="somat:module_type">edaqxr_lite</tag>
 <dim index="0">
  <tag id="core:description"/>
  <tag id="core:label">Time</tag>
  <tag id="core:units">Seconds</tag>
  <data decoder="2" v="0"/>
  <xform scale="2.5e-08" offset="0"/>
 </dim>
 <dim index="1">
  <tag id="core:description"/>
  <tag id="core:label">raw_can1_edaqxr_5508cc</tag>
  <tag id="core:units"/>
  <data decoder="2" v="1"/>
 </dim>
</ch>
=#