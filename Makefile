# Makefile — NeuraEdge build automation
# Requires: iverilog, vvp, gtkwave (optional), python3, numpy

SV2V     ?= sv2v
IVERILOG ?= iverilog
VVP      ?= vvp
GTKWAVE  ?= gtkwave
PYTHON   ?= python3
VIVADO   ?= vivado

SRCDIR   := src
TESTDIR  := tests
BUILDDIR := build

SRC_FILES := $(wildcard $(SRCDIR)/*.sv)

.PHONY: all sim_neuron sim_network wave_neuron wave_network sim_python synth synth_only clean help

all: sim_neuron sim_network

## sim_neuron — compile and run single-neuron unit test
sim_neuron: $(BUILDDIR)/neuron_tb.vvp
	@echo ">>> Running neuron testbench..."
	$(VVP) $(BUILDDIR)/neuron_tb.vvp

$(BUILDDIR)/neuron_tb.vvp: $(SRC_FILES) $(TESTDIR)/neuron_tb.sv | $(BUILDDIR)
	@echo ">>> Compiling neuron testbench..."
	$(IVERILOG) -g2012 -o $@ \
	    $(SRCDIR)/neuron.sv \
	    $(TESTDIR)/neuron_tb.sv

## sim_network — compile and run full integration test
sim_network: $(BUILDDIR)/network_tb.vvp
	@echo ">>> Running network testbench..."
	$(VVP) $(BUILDDIR)/network_tb.vvp

$(BUILDDIR)/network_tb.vvp: $(SRC_FILES) $(TESTDIR)/network_tb.sv | $(BUILDDIR)
	@echo ">>> Compiling network testbench..."
	$(IVERILOG) -g2012 -o $@ \
	    $(SRCDIR)/neuron.sv \
	    $(SRCDIR)/neuron_array.sv \
	    $(SRCDIR)/synapse_mem.sv \
	    $(SRCDIR)/spike_router.sv \
	    $(SRCDIR)/stdp.sv \
	    $(SRCDIR)/scheduler.sv \
	    $(SRCDIR)/encoder.sv \
	    $(SRCDIR)/neuraedge.sv \
	    $(TESTDIR)/network_tb.sv

## wave_neuron — run sim_neuron then open GTKWave
wave_neuron: sim_neuron
	$(GTKWAVE) $(BUILDDIR)/neuron_tb.vcd &

## wave_network — run sim_network then open GTKWave
wave_network: sim_network
	$(GTKWAVE) $(BUILDDIR)/network_tb.vcd &

## sim_python — run XOR network Python simulation
sim_python:
	$(PYTHON) kernels/xor_network.py --simulate

## synth — full Vivado synthesis + implementation → bitstream + benchmark reports
## Requires Vivado 2020.1 or later on PATH (set VIVADO= if not on PATH)
synth:
	@echo ">>> Running Vivado synthesis + implementation for Artix-7 xc7a35tcpg236-1..."
	$(VIVADO) -mode batch -source vivado/synth_artix7.tcl \
	    -log    vivado/vivado_synth.log \
	    -journal vivado/vivado_synth.jou
	@echo ">>> Reports written to vivado/reports/"
	@echo ">>> Bitstream: vivado/neuraedge_basys3.bit"

## synth_only — synthesis only (no implementation or bitstream); faster for resource checks
synth_only:
	@echo ">>> Running Vivado synthesis only for Artix-7 xc7a35tcpg236-1..."
	$(VIVADO) -mode batch -source vivado/synth_artix7.tcl \
	    -tclargs synth_only \
	    -log    vivado/vivado_synth.log \
	    -journal vivado/vivado_synth.jou
	@echo ">>> Post-synthesis report: vivado/reports/utilization_synth.rpt"

## clean — remove build artifacts
clean:
	rm -rf $(BUILDDIR)/
	rm -rf vivado/*.log vivado/*.jou vivado/*.bit vivado/.Xil/

## Create build directory
$(BUILDDIR):
	mkdir -p $(BUILDDIR)

## help — show all targets
help:
	@echo "NeuraEdge Make Targets:"
	@echo "  make sim_neuron    - Run single neuron unit tests"
	@echo "  make sim_network   - Run full chip integration tests"
	@echo "  make wave_neuron   - Run neuron sim + open GTKWave"
	@echo "  make wave_network  - Run network sim + open GTKWave"
	@echo "  make sim_python    - Run Python XOR simulation"
	@echo "  make synth         - Vivado synthesis + implementation (Artix-7)"
	@echo "  make synth_only    - Vivado synthesis only (faster resource check)"
	@echo "  make clean         - Remove build/ and Vivado logs"
	@echo "  make all           - Run sim_neuron + sim_network"
	@echo "  make help          - Show this help"
	@echo ""
	@echo "Tools required: iverilog, vvp, python3 (numpy)"
	@echo "Optional:       sv2v, gtkwave, vivado (for FPGA synthesis)"
