# BRAM-fix validation build script (isolated output dir)
set PART    xc7a100tcsg324-1
set PROJ    neuraedge_bramfix
set TOP     neuraedge_top
set OUTDIR  ./vivado_proj_bramfix

create_project ${PROJ} ${OUTDIR} -part ${PART} -force
set_property SEVERITY Warning [get_drc_checks UCIO-1]

add_files [list \
    rtl/neuron_core.sv     \
    rtl/synapse_memory.sv  \
    rtl/spike_router.sv    \
    rtl/event_encoder.sv   \
    rtl/learning_engine.sv \
    rtl/neuraedge_top.sv   \
]
set_property top ${TOP} [current_fileset]
set_property file_type {SystemVerilog} [get_files *.sv]

add_files -fileset constrs_1 constraints/neuraedge.xdc

set_property generic {
    NUM_COLS=2 NUM_ROWS=2 NUM_NEURONS=64 NUM_SYNAPSES=128
    WEIGHT_W=8 MEM_WIDTH=8 THRESHOLD=200 LEAK_SHIFT=1
    A_PLUS=4 A_MINUS=2 TRACE_INCR=16 TRACE_DECAY=3
    MAX_WEIGHT=255 MIN_WEIGHT=0
    SENSOR_W=8 SENSOR_H=8 NEURON_ADDR_W=6
    TIMESTAMP_W=20 WINDOW_US=1000 WINDOW_MODE=0
    NUM_CLASSES=10 UART_CLK_DIV=868
} [current_fileset]
set_property STEPS.WRITE_BITSTREAM.TCL.PRE [file normalize "scripts/vivado_pre_bitgen.tcl"] [get_runs impl_1]

puts "INFO: Synthesising ${TOP} ..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

open_run synth_1
report_utilization -file ${OUTDIR}/${PROJ}.runs/synth_1/${TOP}_utilization_synth.rpt

puts "INFO: Implementing + writing bitstream ..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

open_run impl_1
report_utilization    -file ${OUTDIR}/${PROJ}.runs/impl_1/utilisation.rpt
report_timing_summary -file ${OUTDIR}/${PROJ}.runs/impl_1/timing.rpt -max_paths 10
report_power          -file ${OUTDIR}/${PROJ}.runs/impl_1/power.rpt

puts "Build complete"
puts "Bit: ${OUTDIR}/${PROJ}.runs/impl_1/${TOP}.bit"
