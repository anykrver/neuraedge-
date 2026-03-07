## neuraedge_basys3.xdc — Vivado XDC constraints for Basys 3 board
## FPGA: Artix-7 xc7a35tcpg236-1
## All IOSTANDARD = LVCMOS33

## ============================================================
## Clock — 100 MHz
## ============================================================
set_property PACKAGE_PIN W5  [get_ports CLK100MHZ]
set_property IOSTANDARD  LVCMOS33 [get_ports CLK100MHZ]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports CLK100MHZ]

## ============================================================
## Switches SW[0..15]
## ============================================================
set_property PACKAGE_PIN V17 [get_ports {SW[0]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[0]}]
set_property PACKAGE_PIN V16 [get_ports {SW[1]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[1]}]
set_property PACKAGE_PIN W16 [get_ports {SW[2]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[2]}]
set_property PACKAGE_PIN W17 [get_ports {SW[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[3]}]
set_property PACKAGE_PIN W15 [get_ports {SW[4]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[4]}]
set_property PACKAGE_PIN V15 [get_ports {SW[5]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[5]}]
set_property PACKAGE_PIN W14 [get_ports {SW[6]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[6]}]
set_property PACKAGE_PIN W13 [get_ports {SW[7]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[7]}]
set_property PACKAGE_PIN V2  [get_ports {SW[8]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[8]}]
set_property PACKAGE_PIN T3  [get_ports {SW[9]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[9]}]
set_property PACKAGE_PIN T2  [get_ports {SW[10]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[10]}]
set_property PACKAGE_PIN R3  [get_ports {SW[11]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[11]}]
set_property PACKAGE_PIN W2  [get_ports {SW[12]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[12]}]
set_property PACKAGE_PIN U1  [get_ports {SW[13]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[13]}]
set_property PACKAGE_PIN T1  [get_ports {SW[14]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[14]}]
set_property PACKAGE_PIN R2  [get_ports {SW[15]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SW[15]}]

## ============================================================
## LEDs LED[0..15]
## ============================================================
set_property PACKAGE_PIN U16 [get_ports {LED[0]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[0]}]
set_property PACKAGE_PIN E19 [get_ports {LED[1]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[1]}]
set_property PACKAGE_PIN U19 [get_ports {LED[2]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[2]}]
set_property PACKAGE_PIN V19 [get_ports {LED[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[3]}]
set_property PACKAGE_PIN W18 [get_ports {LED[4]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[4]}]
set_property PACKAGE_PIN U15 [get_ports {LED[5]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[5]}]
set_property PACKAGE_PIN U14 [get_ports {LED[6]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[6]}]
set_property PACKAGE_PIN V14 [get_ports {LED[7]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[7]}]
set_property PACKAGE_PIN V13 [get_ports {LED[8]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[8]}]
set_property PACKAGE_PIN V3  [get_ports {LED[9]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[9]}]
set_property PACKAGE_PIN W3  [get_ports {LED[10]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[10]}]
set_property PACKAGE_PIN U3  [get_ports {LED[11]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[11]}]
set_property PACKAGE_PIN P3  [get_ports {LED[12]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[12]}]
set_property PACKAGE_PIN N3  [get_ports {LED[13]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[13]}]
set_property PACKAGE_PIN P1  [get_ports {LED[14]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[14]}]
set_property PACKAGE_PIN L1  [get_ports {LED[15]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {LED[15]}]

## ============================================================
## Push Buttons
## ============================================================
set_property PACKAGE_PIN U18 [get_ports BTNC]
set_property IOSTANDARD  LVCMOS33 [get_ports BTNC]
set_property PACKAGE_PIN T17 [get_ports BTNR]
set_property IOSTANDARD  LVCMOS33 [get_ports BTNR]
set_property PACKAGE_PIN W19 [get_ports BTNL]
set_property IOSTANDARD  LVCMOS33 [get_ports BTNL]
set_property PACKAGE_PIN T18 [get_ports BTNU]
set_property IOSTANDARD  LVCMOS33 [get_ports BTNU]
set_property PACKAGE_PIN U17 [get_ports BTND]
set_property IOSTANDARD  LVCMOS33 [get_ports BTND]

## ============================================================
## 7-Segment Display
## Segments: CA=a, CB=b, CC=c, CD=d, CE=e, CF=f, CG=g (active low)
## Anodes: AN[3:0] (active low)
## ============================================================
set_property PACKAGE_PIN W7  [get_ports {SEG[0]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SEG[0]}]
set_property PACKAGE_PIN W6  [get_ports {SEG[1]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SEG[1]}]
set_property PACKAGE_PIN U8  [get_ports {SEG[2]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SEG[2]}]
set_property PACKAGE_PIN V8  [get_ports {SEG[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SEG[3]}]
set_property PACKAGE_PIN U5  [get_ports {SEG[4]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SEG[4]}]
set_property PACKAGE_PIN V5  [get_ports {SEG[5]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SEG[5]}]
set_property PACKAGE_PIN U7  [get_ports {SEG[6]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {SEG[6]}]

set_property PACKAGE_PIN U2  [get_ports {AN[0]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {AN[0]}]
set_property PACKAGE_PIN U4  [get_ports {AN[1]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {AN[1]}]
set_property PACKAGE_PIN V4  [get_ports {AN[2]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {AN[2]}]
set_property PACKAGE_PIN W4  [get_ports {AN[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {AN[3]}]

## ============================================================
## Optional (commented out): UART
## ============================================================
## set_property PACKAGE_PIN B18 [get_ports uart_tx]
## set_property IOSTANDARD  LVCMOS33 [get_ports uart_tx]
## set_property PACKAGE_PIN A18 [get_ports uart_rx]
## set_property IOSTANDARD  LVCMOS33 [get_ports uart_rx]

## ============================================================
## Optional (commented out): JA Pmod header
## ============================================================
## set_property PACKAGE_PIN J1  [get_ports {JA[0]}]
## set_property IOSTANDARD  LVCMOS33 [get_ports {JA[0]}]
## set_property PACKAGE_PIN L2  [get_ports {JA[1]}]
## set_property IOSTANDARD  LVCMOS33 [get_ports {JA[1]}]
## set_property PACKAGE_PIN J2  [get_ports {JA[2]}]
## set_property IOSTANDARD  LVCMOS33 [get_ports {JA[2]}]
## set_property PACKAGE_PIN G2  [get_ports {JA[3]}]
## set_property IOSTANDARD  LVCMOS33 [get_ports {JA[3]}]
