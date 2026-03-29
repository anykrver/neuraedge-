// spike_router.sv
// X-then-Y deterministic-order routing (DOR) mesh NoC router.
// Credit-based flow control, 5-port FIFO per direction.
// Author: Rahul Verma | Apache 2.0
`timescale 1ns / 1ps

module spike_router #(
    parameter int NUM_COLS      = 4,
    parameter int NUM_ROWS      = 4,
    parameter int NEURON_ADDR_W = 6,
    parameter int FIFO_DEPTH    = 4,
    parameter int CUR_COL       = 0,
    parameter int CUR_ROW       = 0,
    parameter int PACKET_W      = 4 * $clog2((NUM_COLS > NUM_ROWS) ? NUM_COLS : NUM_ROWS)
                                + NEURON_ADDR_W
)(
    input logic clk,
    input logic rst_n,

    input  logic [PACKET_W-1:0] in_data_N,
    input  logic                in_valid_N,
    output logic                in_credit_N,
    input  logic [PACKET_W-1:0] in_data_S,
    input  logic                in_valid_S,
    output logic                in_credit_S,
    input  logic [PACKET_W-1:0] in_data_E,
    input  logic                in_valid_E,
    output logic                in_credit_E,
    input  logic [PACKET_W-1:0] in_data_W,
    input  logic                in_valid_W,
    output logic                in_credit_W,
    input  logic [PACKET_W-1:0] in_data_L,
    input  logic                in_valid_L,
    output logic                in_credit_L,

    output logic [PACKET_W-1:0] out_data_N,
    output logic                out_valid_N,
    input  logic                out_credit_N,
    output logic [PACKET_W-1:0] out_data_S,
    output logic                out_valid_S,
    input  logic                out_credit_S,
    output logic [PACKET_W-1:0] out_data_E,
    output logic                out_valid_E,
    input  logic                out_credit_E,
    output logic [PACKET_W-1:0] out_data_W,
    output logic                out_valid_W,
    input  logic                out_credit_W,
    output logic [PACKET_W-1:0] out_data_L,
    output logic                out_valid_L,
    input  logic                out_credit_L,

    output logic [4:0] fifo_overflow
);

    localparam int COORD_W  = $clog2(NUM_COLS > NUM_ROWS ? NUM_COLS : NUM_ROWS);
    localparam int FIFO_PTR = $clog2(FIFO_DEPTH);

    localparam int DST_COL_HI = PACKET_W - 1;
    localparam int DST_COL_LO = PACKET_W - COORD_W;
    localparam int DST_ROW_HI = DST_COL_LO - 1;
    localparam int DST_ROW_LO = DST_COL_LO - COORD_W;

    localparam int DIR_N = 0;
    localparam int DIR_S = 1;
    localparam int DIR_E = 2;
    localparam int DIR_W = 3;
    localparam int DIR_L = 4;

    // ---- Input FIFOs ----------------------------------------
    logic [PACKET_W-1:0] fifo    [0:4][0:FIFO_DEPTH-1];
    logic [FIFO_PTR:0]   wr_ptr  [0:4];
    logic [FIFO_PTR:0]   rd_ptr  [0:4];
    logic [4:0]          overflow_r;

    logic fifo_empty [0:4];
    logic fifo_full  [0:4];

    generate
        for (genvar gd = 0; gd < 5; gd++) begin : fifo_stat
            assign fifo_empty[gd] = (wr_ptr[gd] == rd_ptr[gd]);
            assign fifo_full[gd]  = (wr_ptr[gd][FIFO_PTR-1:0] == rd_ptr[gd][FIFO_PTR-1:0]) &&
                                    (wr_ptr[gd][FIFO_PTR]      != rd_ptr[gd][FIFO_PTR]);
        end
    endgenerate

    // Back-credit to sender: we can accept when FIFO is not full
    assign in_credit_N = ~fifo_full[DIR_N];
    assign in_credit_S = ~fifo_full[DIR_S];
    assign in_credit_E = ~fifo_full[DIR_E];
    assign in_credit_W = ~fifo_full[DIR_W];
    assign in_credit_L = ~fifo_full[DIR_L];
    assign fifo_overflow = overflow_r;

    // Flatten interface signals to arrays for loop indexing
    logic [PACKET_W-1:0] in_data  [0:4];
    logic                in_valid [0:4];
    logic                out_credit_arr [0:4];

    assign in_data[DIR_N]        = in_data_N;   assign in_valid[DIR_N]        = in_valid_N;
    assign in_data[DIR_S]        = in_data_S;   assign in_valid[DIR_S]        = in_valid_S;
    assign in_data[DIR_E]        = in_data_E;   assign in_valid[DIR_E]        = in_valid_E;
    assign in_data[DIR_W]        = in_data_W;   assign in_valid[DIR_W]        = in_valid_W;
    assign in_data[DIR_L]        = in_data_L;   assign in_valid[DIR_L]        = in_valid_L;
    assign out_credit_arr[DIR_N] = out_credit_N;
    assign out_credit_arr[DIR_S] = out_credit_S;
    assign out_credit_arr[DIR_E] = out_credit_E;
    assign out_credit_arr[DIR_W] = out_credit_W;
    assign out_credit_arr[DIR_L] = out_credit_L;

    // ---- X-then-Y DOR routing function ---------------------
    function automatic logic [2:0] route_packet(input logic [PACKET_W-1:0] pkt);
        logic [COORD_W-1:0] dc, dr;
        dc = pkt[DST_COL_HI:DST_COL_LO];
        dr = pkt[DST_ROW_HI:DST_ROW_LO];
        if      (dc > COORD_W'(CUR_COL)) return 3'(DIR_E);
        else if (dc < COORD_W'(CUR_COL)) return 3'(DIR_W);
        else if (dr > COORD_W'(CUR_ROW)) return 3'(DIR_N);
        else if (dr < COORD_W'(CUR_ROW)) return 3'(DIR_S);
        else                              return 3'(DIR_L);
    endfunction

    // ---- Round-robin arbitration — pure function -----------
    function automatic logic [2:0] rr_select(
        input logic [2:0] start,
        input logic [4:0] empty_mask
    );
        logic [2:0] cand;
        rr_select = 3'd7;
        for (int j = 4; j >= 0; j--) begin : rr_arith
            int idx;
            idx  = {29'd0, start} + j;
            cand = 3'(idx % 5);
            if (!empty_mask[cand]) rr_select = cand;
        end
    endfunction

    // ---- Credit counters and output registers ---------------
    logic [FIFO_PTR:0]   credit      [0:4];
    logic [2:0]          rr_ptr      [0:4];
    logic [PACKET_W-1:0] out_data_r  [0:4];
    logic                out_valid_r [0:4];

    // ---- FIFO write (enqueue) ------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int d = 0; d < 5; d++) wr_ptr[d] <= '0;
            overflow_r <= 5'b0;
        end else begin
            for (int d = 0; d < 5; d++) begin
                if (in_valid[d]) begin
                    if (!fifo_full[d]) begin
                        fifo[d][wr_ptr[d][FIFO_PTR-1:0]] <= in_data[d];
                        wr_ptr[d] <= wr_ptr[d] + 1;
                    end else begin
                        overflow_r[d] <= 1'b1;
                    end
                end
            end
        end
    end

    // ---- Credit + arbitration + output ---------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int d = 0; d < 5; d++) begin
                rd_ptr      [d] <= '0;
                credit      [d] <= (FIFO_PTR+1)'(FIFO_DEPTH);
                rr_ptr      [d] <= 3'd0;
                out_data_r  [d] <= '0;
                out_valid_r [d] <= 1'b0;
            end
        end else begin
            logic [4:0] rd_ptr_inc_v;
            rd_ptr_inc_v = 5'b0;

            // FIX BUG-5: single-NBA net-delta credit update
            for (int d = 0; d < 5; d++) begin : credit_update
                logic signed [FIFO_PTR+1:0] delta;
                delta = '0;
                if (out_credit_arr[d] && credit[d] < (FIFO_PTR+1)'(FIFO_DEPTH)) delta = delta + 1;
                if (out_valid_r[d]    && credit[d] > '0)                          delta = delta - 1;
                credit[d] <= credit[d] + delta;
            end

            // FIX BUG-6: per-port independent arbitration
            begin : arb_N_block
                logic [2:0] w; logic [PACKET_W-1:0] h; logic [2:0] dp;
                out_valid_r[DIR_N] <= 1'b0;
                if (credit[DIR_N] > '0) begin
                    w = rr_select(rr_ptr[DIR_N],
                                  {fifo_empty[4],fifo_empty[3],fifo_empty[2],
                                   fifo_empty[1],fifo_empty[0]});
                    if (w != 3'd7) begin
                        h  = fifo[w][rd_ptr[w][FIFO_PTR-1:0]];
                        dp = route_packet(h);
                        if (dp == 3'(DIR_N)) begin
                            rd_ptr_inc_v[w]   = 1'b1;
                            out_data_r[DIR_N] <= h;
                            out_valid_r[DIR_N]<= 1'b1;
                            rr_ptr[DIR_N]     <= (w == 3'd4) ? 3'd0 : w + 1;
                        end
                    end
                end
            end

            begin : arb_S_block
                logic [2:0] w; logic [PACKET_W-1:0] h; logic [2:0] dp;
                out_valid_r[DIR_S] <= 1'b0;
                if (credit[DIR_S] > '0) begin
                    w = rr_select(rr_ptr[DIR_S],
                                  {fifo_empty[4],fifo_empty[3],fifo_empty[2],
                                   fifo_empty[1],fifo_empty[0]});
                    if (w != 3'd7) begin
                        h  = fifo[w][rd_ptr[w][FIFO_PTR-1:0]];
                        dp = route_packet(h);
                        if (dp == 3'(DIR_S)) begin
                            rd_ptr_inc_v[w]   = 1'b1;
                            out_data_r[DIR_S] <= h;
                            out_valid_r[DIR_S]<= 1'b1;
                            rr_ptr[DIR_S]     <= (w == 3'd4) ? 3'd0 : w + 1;
                        end
                    end
                end
            end

            begin : arb_E_block
                logic [2:0] w; logic [PACKET_W-1:0] h; logic [2:0] dp;
                out_valid_r[DIR_E] <= 1'b0;
                if (credit[DIR_E] > '0) begin
                    w = rr_select(rr_ptr[DIR_E],
                                  {fifo_empty[4],fifo_empty[3],fifo_empty[2],
                                   fifo_empty[1],fifo_empty[0]});
                    if (w != 3'd7) begin
                        h  = fifo[w][rd_ptr[w][FIFO_PTR-1:0]];
                        dp = route_packet(h);
                        if (dp == 3'(DIR_E)) begin
                            rd_ptr_inc_v[w]   = 1'b1;
                            out_data_r[DIR_E] <= h;
                            out_valid_r[DIR_E]<= 1'b1;
                            rr_ptr[DIR_E]     <= (w == 3'd4) ? 3'd0 : w + 1;
                        end
                    end
                end
            end

            begin : arb_W_block
                logic [2:0] w; logic [PACKET_W-1:0] h; logic [2:0] dp;
                out_valid_r[DIR_W] <= 1'b0;
                if (credit[DIR_W] > '0) begin
                    w = rr_select(rr_ptr[DIR_W],
                                  {fifo_empty[4],fifo_empty[3],fifo_empty[2],
                                   fifo_empty[1],fifo_empty[0]});
                    if (w != 3'd7) begin
                        h  = fifo[w][rd_ptr[w][FIFO_PTR-1:0]];
                        dp = route_packet(h);
                        if (dp == 3'(DIR_W)) begin
                            rd_ptr_inc_v[w]   = 1'b1;
                            out_data_r[DIR_W] <= h;
                            out_valid_r[DIR_W]<= 1'b1;
                            rr_ptr[DIR_W]     <= (w == 3'd4) ? 3'd0 : w + 1;
                        end
                    end
                end
            end

            begin : arb_L_block
                logic [2:0] w; logic [PACKET_W-1:0] h; logic [2:0] dp;
                out_valid_r[DIR_L] <= 1'b0;
                if (credit[DIR_L] > '0) begin
                    w = rr_select(rr_ptr[DIR_L],
                                  {fifo_empty[4],fifo_empty[3],fifo_empty[2],
                                   fifo_empty[1],fifo_empty[0]});
                    if (w != 3'd7) begin
                        h  = fifo[w][rd_ptr[w][FIFO_PTR-1:0]];
                        dp = route_packet(h);
                        if (dp == 3'(DIR_L)) begin
                            rd_ptr_inc_v[w]   = 1'b1;
                            out_data_r[DIR_L] <= h;
                            out_valid_r[DIR_L]<= 1'b1;
                            rr_ptr[DIR_L]     <= (w == 3'd4) ? 3'd0 : w + 1;
                        end
                    end
                end
            end

            for (int d = 0; d < 5; d++)
                if (rd_ptr_inc_v[d]) rd_ptr[d] <= rd_ptr[d] + 1;
        end
    end

    // ---- Drive output interface signals --------------------
    always_comb begin
        out_data_N = out_data_r[DIR_N];  out_valid_N = out_valid_r[DIR_N];
        out_data_S = out_data_r[DIR_S];  out_valid_S = out_valid_r[DIR_S];
        out_data_E = out_data_r[DIR_E];  out_valid_E = out_valid_r[DIR_E];
        out_data_W = out_data_r[DIR_W];  out_valid_W = out_valid_r[DIR_W];
        out_data_L = out_data_r[DIR_L];  out_valid_L = out_valid_r[DIR_L];
    end

endmodule
