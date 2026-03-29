// sva_bind.sv
// Binds neuraedge_sva assertions to the neuraedge_top DUT.
// Include this file in simulation alongside tb_neuraedge_top.cpp or
// add it to the Makefile sim target with +define+SVA_ENABLE.
//
// Usage (Verilator):
//   verilator --sv --assert ... rtl/*.sv tb/sva_bind.sv
//
// Usage (Icarus):
//   iverilog -g2012 -DSVA_ENABLE rtl/*.sv tb/sva_bind.sv tb/tb_top.v
`timescale 1ns / 1ps

`ifdef SVA_ENABLE
module sva_bind;
    bind neuraedge_top neuraedge_sva #(
        .NUM_NEURONS  (NUM_NEURONS),
        .NUM_SYNAPSES (NUM_SYNAPSES),
        .TRACE_W      (TRACE_W),
        .WEIGHT_W     (WEIGHT_W),
        .PACKET_W     (PACKET_W),
        .WINDOW_US    (WINDOW_US),
        .TIMESTAMP_W  (TIMESTAMP_W)
    ) sva_inst (
        .clk             (clk),
        .rst_n           (rst_n),
        .dvs_valid       (dvs_valid),
        .dvs_ready       (dvs_ready),
        .pkt_valid       (enc_pkt_valid),
        .spike_out_c0    (spike_out[0][0]),
        .mem_we          (le_we[0][0]),
        .mem_wr_data     (le_wr_data[0][0]),
        .mem_rd_valid    (syn_rd_valid[0][0]),
        .infer_timer     (infer_timer),
        .uart_tx         (uart_tx),
        .rst_n_pipe      (1'b1),
        .le_scan_active  (1'b0)
    );
endmodule
`endif
