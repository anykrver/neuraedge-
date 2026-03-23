# ============================================================
# synth.tcl  — Vivado batch synthesis + implementation
# Target:    Nexys A7  (xc7a100tcsg324-1, speed grade -1)
# Top:       neuraedge_top
# Config:    2x2 mesh, 8x8 sensor demo (tile constraint satisfied)
#
# Usage:
#   vivado -mode batch -source scripts/synth.tcl
#
# Outputs (in vivado_proj/neuraedge.runs/impl_1/):
#   neuraedge_top.bit   — FPGA bitstream
#   utilisation.rpt     — resource usage
#   timing.rpt          — WNS / TNS
#   power.rpt           — estimated power
#
# Simulation vs hardware disclaimer:
#   This script assumes pre-synthesis simulation passed (run_sim.sh).
#   Timing closure, CDC, routing congestion, and power integrity are
#   NOT validated by simulation alone. Verify WNS >= 0 in timing.rpt
#   before programming the board.
#
# Version:  2.0.0
# ============================================================

set PART    xc7a100tcsg324-1
set PROJ    neuraedge
set TOP     neuraedge_top
set OUTDIR  ./vivado_proj

create_project ${PROJ} ${OUTDIR} -part ${PART} -force
# Keep intentional unpinned debug/status outputs from blocking bitgen.
set_property SEVERITY Warning [get_drc_checks UCIO-1]

# Add all synthesisable RTL (exclude ILA wrapper and testbenches)
add_files [list \
    rtl/noc_port.sv        \
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

# Override generics for demo config
# SENSOR_W=8/SENSOR_H=8: satisfies TILE_W*TILE_H*2=32 <= 64 (NEURON_ADDR_W=6)
set_property generic {
    NUM_COLS=2 NUM_ROWS=2 NUM_NEURONS=64 NUM_SYNAPSES=512
    WEIGHT_W=8 MEM_WIDTH=8 THRESHOLD=200 LEAK_SHIFT=1
    A_PLUS=4 A_MINUS=2 TRACE_INCR=16 TRACE_DECAY=3
    MAX_WEIGHT=255 MIN_WEIGHT=0
    SENSOR_W=8 SENSOR_H=8 NEURON_ADDR_W=6
    TIMESTAMP_W=20 WINDOW_US=1000 WINDOW_MODE=0
    NUM_CLASSES=10 UART_CLK_DIV=868
} [current_fileset]

puts "INFO: Synthesising ${TOP} ..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis FAILED"
}

puts "INFO: Implementing + writing bitstream ..."
# Light margin-hardening directives for near-zero WNS designs.
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraPostPlacementOpt [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.WRITE_BITSTREAM.TCL.PRE [file normalize "scripts/vivado/pre_bitgen.tcl"] [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation FAILED"
}

open_run impl_1
report_utilization   -file ${OUTDIR}/${PROJ}.runs/impl_1/utilisation.rpt
report_timing_summary -file ${OUTDIR}/${PROJ}.runs/impl_1/timing.rpt -max_paths 10
report_power         -file ${OUTDIR}/${PROJ}.runs/impl_1/power.rpt
report_drc           -file ${OUTDIR}/${PROJ}.runs/impl_1/drc.rpt

# ---- Automated post-implementation verification -------------
set failed_checks {}

# BRAM inference check (count RAMB18-equivalent blocks)
set ramb18_count [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
set ramb36_count [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
set bram_count [expr {$ramb18_count + (2 * $ramb36_count)}]
set bram_status "PASS"
if {$bram_count < 30} {
    set bram_status "FAIL"
    lappend failed_checks "BRAM"
}

# Timing checks
set worst_setup_path [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
set worst_hold_path  [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
set wns [get_property SLACK $worst_setup_path]
set whs [get_property SLACK $worst_hold_path]

set wns_status "PASS"
if {$wns < 0.3} {
    set wns_status "WARN"
    puts "WARNING: WNS below guardband (WNS=${wns} ns < 0.3 ns)"
}

# DRC check: fail only on true error-severity violations.
# Warning-level DRCs are reported but do not block bitgen completion.
set drc_error_count [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
set drc_warn_count  [llength [get_drc_violations -quiet -filter {SEVERITY == Warning}]]
set drc_status "PASS"
if {$drc_error_count > 0} {
    set drc_status "FAIL"
    lappend failed_checks "DRC"
}

puts "\n=============================================================="
puts " NeuraEdge Post-Implementation Check Summary"
puts "=============================================================="
puts [format " %-24s | %-8s | %s" "Check" "Status" "Value"]
puts "--------------------------+----------+-------------------------"
puts [format " %-24s | %-8s | %d (R18=%d R36=%d)" "BRAM18 equivalent" $bram_status $bram_count $ramb18_count $ramb36_count]
puts [format " %-24s | %-8s | %.3f ns" "Worst setup slack (WNS)" $wns_status $wns]
puts [format " %-24s | %-8s | %.3f ns" "Worst hold slack (WHS)" "INFO" $whs]
puts [format " %-24s | %-8s | %d errors, %d warnings" "DRC violations" $drc_status $drc_error_count $drc_warn_count]
puts "==============================================================\n"

if {$bram_count < 30} {
    error "BRAM INFERENCE FAILED: only $bram_count found"
}
if {$drc_error_count > 0} {
    error "DRC FAILED: $drc_error_count error violation(s) detected"
}

puts "\n=============================================="
puts " Build complete"
puts " Bit:  ${OUTDIR}/${PROJ}.runs/impl_1/${TOP}.bit"
puts " Util: ${OUTDIR}/${PROJ}.runs/impl_1/utilisation.rpt"
puts " WNS:  check timing.rpt — must be >= 0 before programming"
puts "==============================================\n"
