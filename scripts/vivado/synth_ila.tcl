# ============================================================
# synth_ila.tcl  — Vivado synthesis with 4x ILA debug cores
# Top:  neuraedge_top_ila (wraps neuraedge_top with ILA probes)
#
# Usage:
#   vivado -mode batch -source scripts/synth_ila.tcl
#
# Resource overhead of ILA:
#   ~8 RAMB18K (4 cores x depth=1024) + ~2000 LUTs for mux
#
# Version: 2.0.0
# ============================================================

set PART    xc7a100tcsg324-1
set PROJ    neuraedge_ila
set TOP     neuraedge_top_ila
set OUTDIR  ./vivado_proj_ila

create_project ${PROJ} ${OUTDIR} -part ${PART} -force

add_files [list \
    rtl/noc_port.sv       
    rtl/neuron_core.sv     rtl/synapse_memory.sv  \
    rtl/spike_router.sv    rtl/event_encoder.sv   \
    rtl/learning_engine.sv rtl/neuraedge_top.sv   \
    rtl/neuraedge_top_ila.sv \
]
set_property top ${TOP} [current_fileset]
set_property file_type {SystemVerilog} [get_files *.sv]
add_files -fileset constrs_1 constraints/neuraedge.xdc

set_property generic {
    NUM_COLS=2 NUM_ROWS=2 NUM_NEURONS=64 NUM_SYNAPSES=128
    SENSOR_W=8 SENSOR_H=8 NEURON_ADDR_W=6
    UART_CLK_DIV=868
} [current_fileset]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

puts "ILA build complete: ${OUTDIR}/${PROJ}.runs/impl_1/${TOP}.bit"
