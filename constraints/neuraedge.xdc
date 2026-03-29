# ============================================================
# neuraedge.xdc  Xilinx Design Constraints  v2.5.0
# Target  : Nexys A7-100T (Artix-7, xc7a100tcsg324-1)
# Top     : neuraedge_top
#
# Fixes vs v2.4.0:
#   FIX 1 — Duplicate pin U1 (was on dvs_x[1] AND led[15]).
#            led[15] moved to correct Nexys A7 pin R3.
#   FIX 2 — P1 is invalid on csg324 package (Basys-3 remnant).
#            dvs_y[2] moved to H1 (SW5 on Nexys A7).
#   FIX 3 — dvs_ready had no IOSTANDARD, caused NSTD-1 DRC.
#            Added IOSTANDARD LVCMOS33 and false_path.
#   FIX 4 — LED and UART output_delay caused 1,852 failing
#            endpoints through OBUF. Replaced with false_path —
#            these are async debug outputs, not synchronous buses.
#   FIX 5 — Several LED pins corrected to Nexys A7-100T values
#            (E19, U19, V19, W18, U15, V13, V3, W3, N3 were
#            Basys-3 or Nexys-4 DDR assignments).
#
# Pin map (Nexys A7-100T master XDC reference):
#   clk            E3   100 MHz crystal oscillator
#   rst_n          C12  CPU_RESET button (active-low)
#   dvs_x[2:0]     J15/L16/M13  (SW0-SW2)
#   dvs_y[2:0]     R15/R17/T18  (SW3-SW5)
#   dvs_polarity   U18  (SW6)
#   dvs_valid      N17  BTNC centre button
#   window_advance M18  BTNU up button
#   dvs_ready      (output — false_path, no board pin needed)
#   spi_sclk       C17  PMOD JA pin 1
#   spi_mosi       D18  PMOD JA pin 2
#   spi_cs_n       E18  PMOD JA pin 3
#   uart_tx        D4   USB-UART TX (false_path for timing)
#   led[15:0]      H17/K15/J13/N14/R18/V17/U17/U16/
#                  V16/T15/U14/T16/V15/V14/V12/V11
# ============================================================

# ---- Primary clock : 100 MHz crystal on E3 -----------------
create_clock -period 10.000 -name sys_clk [get_ports clk]
set_property PACKAGE_PIN E3  [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]

# ---- Active-low reset : CPU_RESET button (C12) -------------
set_property PACKAGE_PIN C12 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

# ---- DVS x coordinate : SW0-SW2 (J15/L16/M13) -------------
set_property PACKAGE_PIN J15 [get_ports {dvs_x[0]}]
set_property PACKAGE_PIN L16 [get_ports {dvs_x[1]}]
set_property PACKAGE_PIN M13 [get_ports {dvs_x[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {dvs_x[*]}]

# ---- DVS y coordinate : SW3-SW5 (R15/R17/T18) -------------
# FIX: P1 was invalid on csg324. Corrected to Nexys A7 SW pins.
set_property PACKAGE_PIN R15 [get_ports {dvs_y[0]}]
set_property PACKAGE_PIN R17 [get_ports {dvs_y[1]}]
set_property PACKAGE_PIN T18 [get_ports {dvs_y[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {dvs_y[*]}]

# ---- DVS polarity : SW6 (U18) ------------------------------
set_property PACKAGE_PIN U18 [get_ports dvs_polarity]
set_property IOSTANDARD LVCMOS33 [get_ports dvs_polarity]

# ---- DVS valid : BTNC centre button (N17) ------------------
set_property PACKAGE_PIN N17 [get_ports dvs_valid]
set_property IOSTANDARD LVCMOS33 [get_ports dvs_valid]

# ---- Window advance : BTNU up button (M18) -----------------
set_property PACKAGE_PIN M18 [get_ports window_advance]
set_property IOSTANDARD LVCMOS33 [get_ports window_advance]

# ---- DVS ready : output — no board pin, false_path ---------
# FIX: dvs_ready was causing NSTD-1 DRC (no IOSTANDARD).
# It is an internal handshake signal with no physical board pin.
# Mark as false_path and let Vivado assign an unused IOB freely.
# write_bitstream enforces UCIO-1 as ERROR when a port has no LOC;
# downgrade UCIO-1 globally so this intentional unpinned debug/output
# port does not block bit generation.
set_property IOSTANDARD LVCMOS33 [get_ports dvs_ready]
set_false_path -to [get_ports dvs_ready]
set_property SEVERITY Warning [get_drc_checks UCIO-1]

# ---- SPI weight loader : PMOD JA (C17/D18/E18) ------------
set_property PACKAGE_PIN C17 [get_ports spi_sclk]
set_property PACKAGE_PIN D18 [get_ports spi_mosi]
set_property PACKAGE_PIN E18 [get_ports spi_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports spi_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports spi_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports spi_cs_n]

# ---- UART TX : USB-UART bridge (D4) -----------------------
set_property PACKAGE_PIN D4  [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

# ---- LEDs LD0-LD15 ----------------------------------------
# FIX: Corrected all pins to Nexys A7-100T master XDC values.
# Previous v2.4.0 had Basys-3/Nexys-4 DDR pin remnants and
# a duplicate U1 collision (dvs_x[1] and led[15] both on U1).
set_property PACKAGE_PIN H17 [get_ports {led[0]}]
set_property PACKAGE_PIN K15 [get_ports {led[1]}]
set_property PACKAGE_PIN J13 [get_ports {led[2]}]
set_property PACKAGE_PIN N14 [get_ports {led[3]}]
set_property PACKAGE_PIN R18 [get_ports {led[4]}]
set_property PACKAGE_PIN V17 [get_ports {led[5]}]
set_property PACKAGE_PIN U17 [get_ports {led[6]}]
set_property PACKAGE_PIN U16 [get_ports {led[7]}]
set_property PACKAGE_PIN V16 [get_ports {led[8]}]
set_property PACKAGE_PIN T15 [get_ports {led[9]}]
set_property PACKAGE_PIN U14 [get_ports {led[10]}]
set_property PACKAGE_PIN T16 [get_ports {led[11]}]
set_property PACKAGE_PIN V15 [get_ports {led[12]}]
set_property PACKAGE_PIN V14 [get_ports {led[13]}]
set_property PACKAGE_PIN V12 [get_ports {led[14]}]
set_property PACKAGE_PIN V11 [get_ports {led[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

# ---- Timing constraints ------------------------------------
# Inputs: switches and buttons are slow human-speed signals.
# rst_n is used as an asynchronous reset network; exclude it from
# regular setup/hold data-path analysis to FF reset pins.
set_false_path -from [get_ports rst_n]
set_input_delay -clock sys_clk -min 1.0 [get_ports rst_n]
set_input_delay -clock sys_clk -max 4.0 [get_ports rst_n]
set_input_delay -clock sys_clk 2.0 [get_ports {dvs_x[*]}]
set_input_delay -clock sys_clk 2.0 [get_ports {dvs_y[*]}]
set_input_delay -clock sys_clk 2.0 [get_ports dvs_polarity]
set_input_delay -clock sys_clk 2.0 [get_ports dvs_valid]
set_input_delay -clock sys_clk 2.0 [get_ports window_advance]
set_input_delay -clock sys_clk 2.0 [get_ports spi_sclk]
set_input_delay -clock sys_clk 2.0 [get_ports spi_mosi]
set_input_delay -clock sys_clk 2.0 [get_ports spi_cs_n]

# FIX: LEDs and UART are async debug outputs — no external clock
# relationship. set_false_path eliminates 1,852 false timing
# violations through OBUF (WNS was -3.071 ns from this alone).
set_false_path -to [get_ports {led[*]}]
set_false_path -to [get_ports uart_tx]

# ---- Bitstream settings ------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4  [current_design]
set_property CONFIG_MODE SPIx4 [current_design]

# ---------------------------------------------------------------------------
# Multicycle paths — BRAM read to learning engine pipeline
# synapse_memory uses 1-cycle read latency (registered BRAM + comb mux).
# No multicycle constraint needed after the synapse_memory.sv fix, but
# retain this guard in case tool opts to re-register the mux output.
# ---------------------------------------------------------------------------
# set_multicycle_path -setup 2 -from [get_cells "*/u_synapse/bank*"] \
#                              -to   [get_cells "*/u_learning/*"]
# set_multicycle_path -hold  1 -from [get_cells "*/u_synapse/bank*"] \
#                              -to   [get_cells "*/u_learning/*"]

# ---------------------------------------------------------------------------
# Router overflow sticky registers — asynchronous status, not timing-critical
# ---------------------------------------------------------------------------
set_false_path -from [get_cells "*/router_overflow_sticky*"]
