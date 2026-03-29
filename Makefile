# ==============================================================================
# Makefile — NeuraEdge v2.5.0
# Target:  Nexys A7-100T (xc7a100tcsg324-1, Artix-7)
# Toolchain: Verilator ≥5.0, Icarus Verilog ≥11, Vivado 2024.x+
#
# Quick reference:
#   make sim        → Verilator regression (all 6 modules)
#   make sim-iv     → Icarus Verilog regression (X-propagation checks)
#   make sim MOD=neuron_core   → single-module Verilator run
#   make synth      → Vivado synthesis + implementation → bitstream
#   make synth-ila  → Same with ILA debug cores inserted
#   make clean      → Remove generated build artefacts
#   make help       → Print this message
# ==============================================================================

SHELL       := /bin/bash
VIVADO      ?= vivado
VERILATOR   ?= verilator
IVERILOG    ?= iverilog

SCRIPTS_VIVADO := scripts/vivado
SCRIPTS_SIM    := scripts/sim

# ------------------------------------------------------------------------------
.PHONY: all sim sim-iv synth synth-ila impl clean help

all: sim synth

# --- Simulation ---------------------------------------------------------------
# Add +define+SVA_ENABLE to enable noc_port link-level SVA assertions
# Bind neuraedge_sva to the DUT via tb/sva_bind.sv for full assertion coverage

sim:
	@bash $(SCRIPTS_SIM)/run_sim.sh $(if $(MOD),$(MOD),)

sim-wave:
	@bash $(SCRIPTS_SIM)/run_sim.sh --wave $(if $(MOD),$(MOD),)

sim-iv:
	@bash $(SCRIPTS_SIM)/run_iverilog.sh $(if $(MOD),$(MOD),)

# --- FPGA build ---------------------------------------------------------------

synth:
	@echo "[neuraedge] Running Vivado synthesis + implementation..."
	$(VIVADO) -mode batch -source $(SCRIPTS_VIVADO)/synth.tcl \
	    -log reports/vivado_synth.log -journal reports/vivado_synth.jou
	@echo "[neuraedge] Done. Check reports/vivado_synth.log and vivado_proj/ for outputs."

synth-ila:
	@echo "[neuraedge] Running Vivado ILA flow..."
	$(VIVADO) -mode batch -source $(SCRIPTS_VIVADO)/synth_ila.tcl \
	    -log reports/vivado_ila.log -journal reports/vivado_ila.jou

impl: synth

# --- Cleanup ------------------------------------------------------------------

clean:
	@echo "[neuraedge] Cleaning generated artefacts..."
	rm -rf vivado_proj/ vivado_proj_ila/ vivado_proj_bramfix/ vivado_proj_bramfix2/
	rm -rf obj_dir_* sim/*.log sim/*.vcd sim/*_iv sim/spike_router_iv_post
	rm -rf xsim.dir/ .Xil/
	rm -f *.log *.jou *.pb *.str *.backup.log *.backup.jou
	rm -f xelab.log xelab.pb xsim.log xsim.jou xvlog.log xvlog.pb
	rm -rf reports/*.log reports/*.jou
	@echo "[neuraedge] Clean done."

# --- Help ---------------------------------------------------------------------

help:
	@echo ""
	@echo "  NeuraEdge v2.5.0 — Makefile targets"
	@echo "  ======================================"
	@echo "  make sim            Verilator regression (all 6 TB modules)"
	@echo "  make sim MOD=<m>    Single-module Verilator run"
	@echo "  make sim-wave       Verilator + open GTKWave on first VCD"
	@echo "  make sim-iv         Icarus Verilog regression"
	@echo "  make synth          Vivado synth + impl + bitstream"
	@echo "  make synth-ila      Vivado synth with ILA debug cores"
	@echo "  make clean          Remove all generated artefacts"
	@echo "  make help           Print this message"
	@echo ""
	@echo "  Overrides:"
	@echo "    VIVADO=<path>     Path to vivado binary (default: vivado)"
	@echo "    VERILATOR=<path>  Path to verilator binary"
	@echo ""
	@echo "  Example:"
	@echo "    make sim MOD=spike_router"
	@echo "    make synth VIVADO=/opt/Xilinx/Vivado/2024.2/bin/vivado"
	@echo ""
