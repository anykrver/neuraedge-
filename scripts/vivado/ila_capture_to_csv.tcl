# ============================================================
# ila_capture_to_csv.tcl — ILA data capture and CSV export
#
# Run this in the Vivado Hardware Manager Tcl console after
# the board is programmed and ILA cores are detected.
#
# Usage (in Vivado Tcl console):
#   source scripts/ila_capture_to_csv.tcl
#
# Or from command line (board must already be connected):
#   vivado -mode tcl -source scripts/ila_capture_to_csv.tcl
#
# Output files (in benchmarks/):
#   ila_spike_capture.csv    — spike_out timing data
#   ila_stdp_capture.csv     — weight update events
#   ila_classifier_capture.csv — classification output
#
# These CSVs feed directly into benchmark.py's
# parse_spike_log() and measurement pipeline.
# ============================================================

set OUTDIR "benchmarks"
file mkdir $OUTDIR

# ---- Connect to hardware ------------------------------------
puts "INFO: Connecting to hardware server ..."
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target

# Get device handle (assumes single device on chain)
set device [lindex [get_hw_devices] 0]
current_hw_device $device
puts "INFO: Connected to [get_property PART $device]"

# ---- Program with ILA bitstream + probes --------------------
set BIT_FILE "vivado_proj_ila/neuraedge_ila.runs/impl_1/neuraedge_top.bit"
set LTX_FILE "vivado_proj_ila/neuraedge_ila.runs/impl_1/neuraedge_top.ltx"

if {![file exists $BIT_FILE]} {
    error "Bitstream not found: $BIT_FILE\nRun synth_ila.tcl first."
}

puts "INFO: Programming device ..."
set_property PROGRAM.FILE $BIT_FILE $device
if {[file exists $LTX_FILE]} {
    set_property PROBES.FILE $LTX_FILE $device
} else {
    puts "WARNING: .ltx probe file not found. Probes will be unnamed."
}
program_hw_devices $device
puts "INFO: Device programmed."

# ---- Helper: arm ILA and wait for trigger ------------------
proc capture_ila {core_name trigger_probe trigger_val csv_path {timeout_ms 5000}} {
    puts "INFO: Arming ${core_name} ..."

    # Get the ILA core handle
    set core [get_hw_ilas -filter "CELL_NAME == ${core_name}"]
    if {[llength $core] == 0} {
        puts "WARNING: ILA core ${core_name} not found — skipping"
        return
    }

    # Set trigger: rising edge on specified probe
    set_property CONTROL.TRIGGER_POSITION 512 $core
    set_property CONTROL.TRIGGER_CONDITION AND $core
    set_property TRIGGER_COMPARE_VALUE eq1'b1 \
        [get_hw_probes ${trigger_probe} -of_objects $core]

    # Set capture mode: always (capture every sample)
    set_property CONTROL.CAPTURE_MODE ALWAYS $core

    # Arm the ILA
    run_hw_ila $core
    puts "INFO: ${core_name} armed. Trigger: ${trigger_probe} = ${trigger_val}"
    puts "INFO: Waiting up to ${timeout_ms} ms for trigger ..."

    # Poll for trigger
    set start_ms [clock milliseconds]
    while {1} {
        set status [get_property STATUS.STATE $core]
        if {$status eq "Idle"} {
            puts "INFO: ${core_name} triggered and captured."
            break
        }
        if {([clock milliseconds] - $start_ms) > $timeout_ms} {
            puts "WARNING: ${core_name} trigger timeout after ${timeout_ms} ms"
            stop_hw_ila $core
            break
        }
        after 50
    }

    # Upload and export
    upload_hw_ila_data $core
    set data [get_hw_ila_data -of_objects $core]
    write_hw_ila_data -csv_file ${csv_path} $data
    puts "INFO: Exported to ${csv_path}"
}

# ---- ILA 0: Spike activity capture --------------------------
# Trigger: enc_pkt_valid = 1 (DVS event entering NoC)
puts "\n---- ILA 0: Spike activity ---------------------------------"
puts "Inject DVS events now. Capture will trigger on enc_pkt_valid."
capture_ila \
    "u_ila_spike" \
    "u_ila_spike/probe5[1]" \
    "1" \
    "${OUTDIR}/ila_spike_capture.csv" \
    10000

# ---- ILA 1: STDP weight updates ----------------------------
# Trigger: le_we = 1 (learning engine writing a weight)
puts "\n---- ILA 1: STDP weight updates ---------------------------"
puts "Ensure STDP is active (learning mode, spikes present)."
capture_ila \
    "u_ila_stdp" \
    "u_ila_stdp/probe3" \
    "1" \
    "${OUTDIR}/ila_stdp_capture.csv" \
    10000

# ---- ILA 2: Classifier output ------------------------------
# Trigger: result_valid = 1 (inference window complete)
puts "\n---- ILA 2: Classifier output -----------------------------"
puts "Run a full N-MNIST inference window. Trigger on result_valid."
capture_ila \
    "u_ila_classifier" \
    "u_ila_classifier/probe3[5]" \
    "1" \
    "${OUTDIR}/ila_classifier_capture.csv" \
    30000

# ---- Parse spike rate from CSV ------------------------------
puts "\n---- Computing spike rate from ILA 0 capture ---------------"
proc compute_spike_rate_from_csv {csv_path clk_mhz} {
    if {![file exists $csv_path]} {
        puts "  CSV not found: $csv_path"
        return 0
    }
    set fh [open $csv_path r]
    set header [gets $fh]

    # Find enc_pkt_valid column index
    set cols [split $header ","]
    set valid_col -1
    for {set i 0} {$i < [llength $cols]} {incr i} {
        if {[string match "*pkt_valid*" [lindex $cols $i]]} {
            set valid_col $i
        }
    }

    if {$valid_col < 0} {
        puts "  enc_pkt_valid column not found in CSV"
        close $fh
        return 0
    }

    set pulse_count 0
    set sample_count 0
    set prev_val 0
    while {[gets $fh line] >= 0} {
        set fields [split $line ","]
        if {[llength $fields] <= $valid_col} continue
        set val [string trim [lindex $fields $valid_col]]
        if {$val eq "1" && $prev_val eq "0"} {
            incr pulse_count
        }
        set prev_val $val
        incr sample_count
    }
    close $fh

    set window_ns [expr {$sample_count * (1000.0 / $clk_mhz)}]
    set window_s  [expr {$window_ns / 1e9}]
    set rate_M    [expr {$pulse_count / $window_s / 1e6}]

    puts "  Samples:    $sample_count"
    puts "  Window:     [format %.2f [expr {$window_ns/1000.0}]] µs"
    puts "  Pkt pulses: $pulse_count"
    puts "  Event rate: [format %.3f $rate_M] M events/sec"
    return $rate_M
}

set rate [compute_spike_rate_from_csv \
    "${OUTDIR}/ila_spike_capture.csv" 100]

puts "\n============================================================"
puts " ILA capture complete"
puts " Files:"
puts "   ${OUTDIR}/ila_spike_capture.csv"
puts "   ${OUTDIR}/ila_stdp_capture.csv"
puts "   ${OUTDIR}/ila_classifier_capture.csv"
puts ""
puts " Run benchmark.py to fold these into the results table:"
puts "   python software/benchmark.py \\"
puts "     --sim-log benchmarks/ila_spike_capture.csv"
puts "============================================================"
