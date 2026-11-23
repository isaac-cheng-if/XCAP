read_verilog -sv C:/dev/xcap/rtl/xcap_txaudio.sv
synth_design -top xcap_txaudio -part xcau15p-ffvb676-2-i -mode out_of_context
puts OOC_OK
