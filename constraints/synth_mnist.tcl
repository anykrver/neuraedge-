# synth_mnist.tcl — Vivado synthesis script for neuraedge_mnist (128-neuron MNIST)
# Target: Artix-7 xc7a35tcpg236-1 (Basys 3), 100 MHz
#
# Usage (Vivado Tcl console or batch mode):
#   vivado -mode batch -source constraints/synth_mnist.tcl
#
# The weight_mem array in synapse_mem_128 is 128 K bits (16384 entries × 8 bits).
# Vivado's default memory dissolution limit is 65536 bits, which causes:
#   "Memory ... is too large."
# The line below raises the limit to 131072 bits so Vivado can infer the four
# 18 Kb BRAM tiles that (* ram_style = "block" *) already requests.
set_param synth.elaboration.rodinMoreOptions \
    {rt::set_parameter dissolveMemorySizeLimit 131072}

# Source files
set src_files [list \
    src/neuron.sv \
    src/neuron_array.sv \
    src/synapse_mem_128.sv \
    src/spike_router_128.sv \
    src/decoder.sv \
    src/stdp.sv \
    src/scheduler.sv \
    src/encoder.sv \
    src/neuraedge_mnist.sv \
]

read_verilog -sv $src_files
read_xdc constraints/neuraedge_basys3.xdc

synth_design -top neuraedge_mnist \
             -part xc7a35tcpg236-1 \
             -flatten_hierarchy rebuilt

report_utilization
report_timing_summary -delay_type min_max -report_unconstrained \
                      -check_timing_verbose -max_paths 10 -input_pins
