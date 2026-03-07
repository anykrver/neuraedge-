# synth_artix7.tcl — Vivado batch synthesis + implementation for NeuraEdge
# Target: Digilent Basys 3 — Artix-7 xc7a35tcpg236-1 (speed grade -1), 100 MHz
#
# Usage (from repository root):
#   vivado -mode batch -source vivado/synth_artix7.tcl
#   vivado -mode batch -source vivado/synth_artix7.tcl -tclargs synth_only
#
# Outputs written to vivado/reports/:
#   utilization_synth.rpt   — post-synthesis resource utilisation
#   utilization_impl.rpt    — post-implementation resource utilisation
#   timing_summary.rpt      — post-implementation timing summary (WNS, TNS, Fmax)
#   power_summary.rpt       — post-implementation power estimate
#   drc.rpt                 — design-rule check results

# -------------------------------------------------------------------------
# 0. Configuration
# -------------------------------------------------------------------------
set PART        "xc7a35tcpg236-1"
set TOP         "neuraedge_top"
set PROJ_DIR    "[file normalize [file dirname [info script]]]"
set REPO_ROOT   "[file normalize ${PROJ_DIR}/.."]"
set REPORT_DIR  "${PROJ_DIR}/reports"
set SYNTH_ONLY  0

if { [llength $argv] > 0 && [lindex $argv 0] eq "synth_only" } {
    set SYNTH_ONLY 1
    puts "INFO: synth_only mode — skipping implementation and bitstream."
}

file mkdir ${REPORT_DIR}

# -------------------------------------------------------------------------
# 1. Source file list (all SystemVerilog sources in dependency order)
# -------------------------------------------------------------------------
set SRC_FILES [list \
    ${REPO_ROOT}/src/neuron.sv         \
    ${REPO_ROOT}/src/neuron_array.sv   \
    ${REPO_ROOT}/src/synapse_mem.sv    \
    ${REPO_ROOT}/src/spike_router.sv   \
    ${REPO_ROOT}/src/stdp.sv           \
    ${REPO_ROOT}/src/encoder.sv        \
    ${REPO_ROOT}/src/scheduler.sv      \
    ${REPO_ROOT}/src/neuraedge.sv      \
    ${REPO_ROOT}/src/neuraedge_top.sv  \
]

set XDC_FILE "${REPO_ROOT}/constraints/neuraedge_basys3.xdc"

# -------------------------------------------------------------------------
# 2. Create in-memory project (no .xpr written to disk)
# -------------------------------------------------------------------------
puts "INFO: Creating in-memory project for part ${PART}..."
create_project -in_memory -part ${PART}
set_property TARGET_LANGUAGE  SystemVerilog [current_project]
set_property DEFAULT_LIB      work         [current_project]

# -------------------------------------------------------------------------
# 3. Add sources
# -------------------------------------------------------------------------
puts "INFO: Adding source files..."
foreach f ${SRC_FILES} {
    if { [file exists ${f}] } {
        read_verilog -sv ${f}
    } else {
        puts "ERROR: Source file not found: ${f}"
        exit 1
    }
}

puts "INFO: Adding constraints..."
if { [file exists ${XDC_FILE}] } {
    read_xdc ${XDC_FILE}
} else {
    puts "ERROR: Constraints file not found: ${XDC_FILE}"
    exit 1
}

# -------------------------------------------------------------------------
# 4. Synthesis
# -------------------------------------------------------------------------
puts "INFO: Running synthesis (top = ${TOP})..."
synth_design \
    -top     ${TOP}   \
    -part    ${PART}  \
    -flatten_hierarchy rebuilt \
    -directive Default

puts "INFO: Writing post-synthesis utilisation report..."
report_utilization \
    -file  ${REPORT_DIR}/utilization_synth.rpt \
    -hierarchical

puts "INFO: Writing post-synthesis timing estimate..."
report_timing_summary \
    -delay_type  min_max           \
    -report_unconstrained          \
    -check_timing_verbose          \
    -max_paths   10                \
    -input_pins                    \
    -file  ${REPORT_DIR}/timing_summary_synth.rpt

if { ${SYNTH_ONLY} } {
    puts "INFO: synth_only — done."
    exit 0
}

# -------------------------------------------------------------------------
# 5. Optimisation & implementation
# -------------------------------------------------------------------------
puts "INFO: Running opt_design..."
opt_design

puts "INFO: Running place_design..."
place_design

puts "INFO: Running route_design..."
route_design

# -------------------------------------------------------------------------
# 6. Post-implementation reports
# -------------------------------------------------------------------------
puts "INFO: Writing post-implementation reports..."

report_utilization \
    -file  ${REPORT_DIR}/utilization_impl.rpt \
    -hierarchical

report_timing_summary \
    -delay_type  min_max           \
    -report_unconstrained          \
    -check_timing_verbose          \
    -max_paths   10                \
    -input_pins                    \
    -datasheet                     \
    -file  ${REPORT_DIR}/timing_summary.rpt

report_power \
    -file  ${REPORT_DIR}/power_summary.rpt

report_drc \
    -file  ${REPORT_DIR}/drc.rpt

report_clock_utilization \
    -file  ${REPORT_DIR}/clock_utilization.rpt

# -------------------------------------------------------------------------
# 7. Bitstream generation
# -------------------------------------------------------------------------
puts "INFO: Generating bitstream..."
write_bitstream \
    -force \
    ${PROJ_DIR}/neuraedge_basys3.bit

puts ""
puts "==========================================================="
puts " NeuraEdge — Artix-7 synthesis + implementation complete"
puts " Reports : ${REPORT_DIR}/"
puts " Bitstream: ${PROJ_DIR}/neuraedge_basys3.bit"
puts "==========================================================="
