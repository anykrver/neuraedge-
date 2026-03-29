#!/usr/bin/env bash
# ============================================================
# run_iverilog.sh  — Icarus Verilog simulation (alternative to Verilator)
#
# Runs the SystemVerilog testbenches with Icarus Verilog.
# These validate X-propagation behaviour that Verilator masks
# with its --x-initial 0 default.
#
# Requirements:  iverilog >= 11  (apt: iverilog)
#
# Usage:
#   ./scripts/run_iverilog.sh
#   ./scripts/run_iverilog.sh neuron_core   # one module only
# ============================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTL="${REPO}/rtl"
TB="${REPO}/tb"
SIM="${REPO}/sim"
mkdir -p "${SIM}"

# Git Bash on Windows often exposes Icarus as *.exe only.
if command -v iverilog >/dev/null 2>&1; then
    IV="iverilog"
elif command -v iverilog.exe >/dev/null 2>&1; then
    IV="iverilog.exe"
else
    echo "[FAIL] iverilog not found in PATH"
    exit 1
fi

USE_WIN_PATHS=0
[[ "${IV}" == *.exe ]] && USE_WIN_PATHS=1

to_win_path() {
    local P="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "${P}"
    elif command -v wslpath >/dev/null 2>&1; then
        wslpath -w "${P}"
    else
        echo "${P}"
    fi
}

if command -v vvp >/dev/null 2>&1; then
    VVP="vvp"
elif command -v vvp.exe >/dev/null 2>&1; then
    VVP="vvp.exe"
else
    echo "[FAIL] vvp not found in PATH"
    exit 1
fi

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GRN}  [PASS]${NC} $1"; }
fail() { echo -e "${RED}  [FAIL]${NC} $1"; }
info() { echo -e "${YLW}  ...${NC} $1"; }

OVERALL=0
ONLY="${1:-}"

run_iv_tb() {
    local MOD="$1" RTL_FILE="$2" TB_FILE="$3"
    [[ -n "${ONLY}" && "${ONLY}" != "${MOD}" ]] && return 0
    local OUT="${SIM}/${MOD}_iv"
    local LOG="${SIM}/${MOD}_iv.log"
    local RTL_ARG="${RTL_FILE}"
    local TB_ARG="${TB_FILE}"
    local OUT_ARG="${OUT}"

    if [[ ${USE_WIN_PATHS} -eq 1 ]]; then
        RTL_ARG="$(to_win_path "${RTL_FILE}")"
        TB_ARG="$(to_win_path "${TB_FILE}")"
        OUT_ARG="$(to_win_path "${OUT}")"
    fi

    info "iverilog: ${MOD} ..."
    if ! "${IV}" -g2012 -Wall -o "${OUT_ARG}" "${RTL_ARG}" "${TB_ARG}" 2>&1; then
        fail "${MOD}: iverilog compile error"; OVERALL=1; return
    fi
    if ! "${VVP}" "${OUT_ARG}" 2>&1 | tee "${LOG}"; then
        fail "${MOD}: runtime error"; OVERALL=1; return
    fi
    if grep -q "\[FAIL\]" "${LOG}"; then
        fail "${MOD}: FAILED"; OVERALL=1
    else
        pass "${MOD}: OK"
    fi
}

echo ""
echo "============================================================"
echo " NeuraEdge Icarus Verilog Simulation"
echo "============================================================"
echo ""

run_iv_tb "neuron_core"     "${RTL}/neuron_core.sv"     "${TB}/neuron_core_tb.sv"
run_iv_tb "synapse_memory"  "${RTL}/synapse_memory.sv"  "${TB}/synapse_memory_tb.sv"
run_iv_tb "spike_router"    "${RTL}/spike_router.sv"    "${TB}/spike_router_tb.sv"
run_iv_tb "event_encoder"   "${RTL}/event_encoder.sv"   "${TB}/event_encoder_tb.sv"
run_iv_tb "learning_engine" "${RTL}/learning_engine.sv" "${TB}/learning_engine_tb.sv"

echo ""
if [[ $OVERALL -eq 0 ]]; then
    echo -e "${GRN} ALL ICARUS TESTS PASSED${NC}"
else
    echo -e "${RED} SOME ICARUS TESTS FAILED${NC}"
fi
echo "============================================================"
[[ $OVERALL -eq 0 ]] && exit 0 || exit 1
