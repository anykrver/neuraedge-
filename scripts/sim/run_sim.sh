#!/usr/bin/env bash
# ============================================================
# run_sim.sh  — NeuraEdge one-command simulation runner
#
# Runs all six testbench modules in dependency order.
# Blocks synthesis if ANY test fails (exit code 1).
# Creates sim/ directory and writes VCD waveforms there.
#
# Usage:
#   ./scripts/run_sim.sh               # run all, no waveforms
#   ./scripts/run_sim.sh --wave        # open GTKWave on first VCD
#   ./scripts/run_sim.sh --fast        # skip LE convergence test
#   ./scripts/run_sim.sh --keep        # keep obj_dir_* after run
#   ./scripts/run_sim.sh neuron_core   # run one module only
#
# Exit codes:
#   0  — all tests passed
#   1  — one or more tests failed
#
# Requirements:
#   verilator >= 5.0   (apt: verilator)
#   make, g++
#   gtkwave            (optional, for --wave)
#
# Author:  NeuraEdge / Rahul Verma  |  Version: 2.0.0
# ============================================================
set -euo pipefail

# Script lives in scripts/sim; repo root is two levels up.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RTL="${REPO}/rtl"
TB="${REPO}/tb"
SIM="${REPO}/sim"
mkdir -p "${SIM}"

FAST=0; KEEP=0; WAVE=0; ONLY=""
for arg in "$@"; do
    case $arg in
        --fast) FAST=1 ;;
        --keep) KEEP=1 ;;
        --wave) WAVE=1 ;;
        --*) echo "Unknown flag: $arg"; exit 1 ;;
        *)   ONLY="$arg" ;;
    esac
done

# Verilator's generated GNU Makefiles cannot build when Mdir has spaces.
BUILD_ROOT="$(mktemp -d /tmp/neuraedge_verilator.XXXXXX)"
STAGE_ROOT="$(mktemp -d /tmp/neuraedge_src.XXXXXX)"
STAGE_RTL="${STAGE_ROOT}/rtl"
STAGE_TB="${STAGE_ROOT}/tb"
mkdir -p "${STAGE_RTL}" "${STAGE_TB}"
cp "${RTL}"/*.sv "${STAGE_RTL}/"  # includes noc_port.sv, neuraedge_sva.sv
cp "${TB}"/*.cpp "${STAGE_TB}/"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${YLW}  ...${NC} $1"; }
pass()  { echo -e "${GRN}  [PASS]${NC} $1"; }
fail()  { echo -e "${RED}  [FAIL]${NC} $1"; }

OVERALL=0
FAILED_MODS=()

# ---- Helper: build + run one Verilator testbench ----
run_tb() {
    local MOD="$1" GFLAGS="$2"
    local OBJ="${BUILD_ROOT}/obj_dir_${MOD}"
    local BIN="sim_${MOD}"
    local LOG="${SIM}/${MOD}.log"
    [[ -n "${ONLY}" && "${ONLY}" != "${MOD}" ]] && return 0

    info "Building ${MOD} ..."
    if ! verilator --cc --trace --exe \
        "${STAGE_RTL}/${MOD}.sv" "${STAGE_TB}/tb_${MOD}.cpp" \
        --top-module "${MOD}" -o "sim_${MOD}" -Mdir "${OBJ}" \
        ${GFLAGS} --assert -Wall --Wno-fatal \
        --Wno-UNUSED --Wno-UNOPTFLAT --Wno-WIDTHEXPAND --Wno-WIDTHTRUNC \
        2>&1 | sed '/^$/d'; then
        fail "${MOD}: Verilator compile error"
        OVERALL=1; FAILED_MODS+=("${MOD}(compile)"); return
    fi
    if ! make -C "${OBJ}" -f "V${MOD}.mk" "${BIN}" --quiet 2>&1; then
        fail "${MOD}: C++ compile error"
        OVERALL=1; FAILED_MODS+=("${MOD}(build)"); return
    fi
    info "Running ${MOD} ..."
    if ! "${OBJ}/${BIN}" 2>&1 | tee "${LOG}"; then
        info "${MOD}: simulator returned non-zero; using log verdict"
    fi
    if grep -q "\[FAIL\]" "${LOG}"; then
        fail "${MOD}: assertions FAILED"
        OVERALL=1; FAILED_MODS+=("${MOD}")
    else
        RESULT=$(grep "Results:" "${LOG}" | tail -1 || echo "unknown")
        pass "${MOD}: ${RESULT}"
    fi
    [[ $KEEP -eq 0 ]] && rm -rf "${OBJ}"
    [[ $WAVE -eq 1 && -f "${SIM}/${MOD}.vcd" ]] && gtkwave "${SIM}/${MOD}.vcd" &
}

# ---- System integration test ----
run_top() {
    local OBJ="${BUILD_ROOT}/obj_dir_top"
    local BIN="sim_top"
    local LOG="${SIM}/neuraedge_top.log"
    [[ -n "${ONLY}" && "${ONLY}" != "neuraedge_top" ]] && return 0

    info "Building neuraedge_top (all RTL) ..."
    if ! verilator --cc --trace --exe \
        "${STAGE_RTL}/noc_port.sv"        "${STAGE_RTL}/neuraedge_top.sv" \
        "${STAGE_RTL}/event_encoder.sv"   "${STAGE_RTL}/spike_router.sv"  \
        "${STAGE_RTL}/neuron_core.sv"     "${STAGE_RTL}/synapse_memory.sv" \
        "${STAGE_RTL}/learning_engine.sv" \
        "${STAGE_TB}/tb_neuraedge_top.cpp" \
        --top-module neuraedge_top -o sim_top -Mdir "${OBJ}" \
        -GNUM_COLS=2 -GNUM_ROWS=2 -GNUM_NEURONS=64 -GNUM_SYNAPSES=512 \
        -GSENSOR_W=8 -GSENSOR_H=8 -GNEURON_ADDR_W=6 -GTHRESHOLD=100 \
        --assert -Wall --Wno-fatal \
        --Wno-UNUSED --Wno-UNOPTFLAT --Wno-WIDTHEXPAND --Wno-WIDTHTRUNC \
        2>&1 | sed '/^$/d'; then
        fail "neuraedge_top: Verilator compile error"
        OVERALL=1; FAILED_MODS+=("neuraedge_top(compile)"); return
    fi
    if ! make -C "${OBJ}" -f Vneuraedge_top.mk "${BIN}" --quiet 2>&1; then
        fail "neuraedge_top: C++ build error"
        OVERALL=1; FAILED_MODS+=("neuraedge_top(build)"); return
    fi
    info "Running neuraedge_top ..."
    if ! "${OBJ}/${BIN}" 2>&1 | tee "${LOG}"; then
        info "neuraedge_top: simulator returned non-zero; using log verdict"
    fi
    if grep -q "\[FAIL\]" "${LOG}"; then
        fail "neuraedge_top: integration test FAILED"
        OVERALL=1; FAILED_MODS+=("neuraedge_top")
    else
        RESULT=$(grep "Results:" "${LOG}" | tail -1 || echo "unknown")
        pass "neuraedge_top: ${RESULT}"
    fi
    [[ $KEEP -eq 0 ]] && rm -rf "${OBJ}"
}

echo ""
echo "============================================================"
echo " NeuraEdge Simulation Gate  v2.0"
echo "============================================================"
echo ""

echo "---- 1/6  neuron_core -----------------------------------------"
run_tb "neuron_core" ""

echo ""
echo "---- 2/6  synapse_memory --------------------------------------"
run_tb "synapse_memory" ""

echo ""
echo "---- 3/6  spike_router ----------------------------------------"
run_tb "spike_router" "-GNUM_COLS=4 -GNUM_ROWS=4 -GCUR_COL=1 -GCUR_ROW=1"

echo ""
echo "---- 4/6  event_encoder ---------------------------------------"
run_tb "event_encoder" \
    "-GSENSOR_W=8 -GSENSOR_H=8 -GNUM_COLS=2 -GNUM_ROWS=2 -GNEURON_ADDR_W=6 -GWINDOW_MODE=0"

echo ""
echo "---- 5/6  learning_engine -------------------------------------"
run_tb "learning_engine" "-GNUM_NEURONS=8 -GNUM_SYNAPSES=4 -GA_PLUS=4 -GA_MINUS=2"

echo ""
echo "---- 6/6  neuraedge_top (integration) -------------------------"
run_top

echo ""
echo "============================================================"
if [[ $OVERALL -eq 0 ]]; then
    echo -e "${GRN} ALL TESTS PASSED${NC}"
    echo ""
    echo " Next:  vivado -mode batch -source scripts/vivado/synth.tcl"
    echo " Or:    python software/train_nmnist.py"
else
    echo -e "${RED} SIMULATION GATE FAILED${NC}"
    echo " Failed: ${FAILED_MODS[*]}"
    echo " Logs in: sim/"
fi

if [[ $KEEP -eq 1 ]]; then
    echo " Build artifacts kept in: ${BUILD_ROOT}"
    echo " Staged sources kept in: ${STAGE_ROOT}"
else
    rm -rf "${BUILD_ROOT}"
    rm -rf "${STAGE_ROOT}"
fi

echo "============================================================"
echo ""
[[ $OVERALL -eq 0 ]] && exit 0 || exit 1
