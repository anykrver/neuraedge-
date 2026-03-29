// event_encoder.sv
// DVS event camera → spike packet encoder for NeuraEdge.
// 2-stage pipeline: spatial decode → neuron_id pack → output FIFO.
// Author: Rahul Verma | Apache 2.0
`timescale 1ns / 1ps

module event_encoder #(
    parameter int SENSOR_W      = 8,
    parameter int SENSOR_H      = 8,
    parameter int NUM_COLS      = 2,
    parameter int NUM_ROWS      = 2,
    parameter int NEURON_ADDR_W = 6,
    parameter int TIMESTAMP_W   = 20,
    parameter int WINDOW_US     = 1000,
    parameter int WINDOW_MODE   = 0,
    parameter int FIFO_DEPTH    = 4,
    // PACKET_W promoted to parameter for port-list visibility.
    parameter int PACKET_W     = 4 * $clog2((NUM_COLS > NUM_ROWS) ? NUM_COLS : NUM_ROWS)
                               + NEURON_ADDR_W
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [$clog2(SENSOR_W)-1:0]  dvs_x,
    input  logic [$clog2(SENSOR_H)-1:0]  dvs_y,
    input  logic                          dvs_polarity,
    input  logic [TIMESTAMP_W-1:0]        dvs_timestamp,
    input  logic                          dvs_valid,
    output logic                          dvs_ready,

    input  logic                          window_advance,

    output logic [PACKET_W-1:0]           pkt_data,
    output logic                          pkt_valid,
    input  logic                          pkt_ready,

    output logic [31:0]                   events_accepted,
    output logic [31:0]                   events_dropped,
    output logic                          fifo_overflow
);

    localparam int COORD_W    = $clog2(NUM_COLS > NUM_ROWS ? NUM_COLS : NUM_ROWS);
    localparam int SENSOR_X_W = $clog2(SENSOR_W);
    localparam int SENSOR_Y_W = $clog2(SENSOR_H);
    localparam int TILE_W     = SENSOR_W / NUM_COLS;
    localparam int TILE_H     = SENSOR_H / NUM_ROWS;
    localparam int LOCAL_X_W  = $clog2(TILE_W + 1);  // +1: handle non-power-of-2 tile
    localparam int LOCAL_Y_W  = $clog2(TILE_H + 1);
    localparam int FIFO_PTR_W = $clog2(FIFO_DEPTH);

    // ---- Stage 1 pipeline registers ------------------------
    logic                   s1_valid;
    logic [COORD_W-1:0]     s1_tile_col;
    logic [COORD_W-1:0]     s1_tile_row;
    logic [LOCAL_X_W-1:0]   s1_local_x;
    logic [LOCAL_Y_W-1:0]   s1_local_y;
    logic                   s1_polarity;

    // ---- Stage 2 pipeline registers ------------------------
    logic                   s2_valid;
    logic [PACKET_W-1:0]    s2_packet;

    // ---- Window control ------------------------------------
    logic [TIMESTAMP_W-1:0] window_start;
    logic in_window;

    assign in_window = (WINDOW_MODE == 0) ? 1'b1 :
                       (dvs_timestamp >= window_start &&
                        dvs_timestamp <  window_start + TIMESTAMP_W'(WINDOW_US));

    logic fifo_full_w;
    logic accept;
    assign accept    = dvs_valid && in_window && !fifo_full_w;
    assign dvs_ready = !fifo_full_w;

    // ---- Stage 1: spatial decode ---------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid    <= 1'b0;
            s1_tile_col <= '0;
            s1_tile_row <= '0;
            s1_local_x  <= '0;
            s1_local_y  <= '0;
            s1_polarity <= 1'b0;
        end else begin
            s1_valid    <= accept;
            s1_tile_col <= COORD_W'(dvs_x / SENSOR_X_W'(TILE_W));
            s1_tile_row <= COORD_W'(dvs_y / SENSOR_Y_W'(TILE_H));
            s1_local_x  <= LOCAL_X_W'(dvs_x % SENSOR_X_W'(TILE_W));
            s1_local_y  <= LOCAL_Y_W'(dvs_y % SENSOR_Y_W'(TILE_H));
            s1_polarity <= dvs_polarity;
        end
    end

    // ---- Stage 2: neuron_id compute + pack -----------------
    // FIX BUG-8: use wider intermediate before truncating to NEURON_ADDR_W
    localparam int NID_FULL_W = LOCAL_Y_W + $clog2(TILE_W) + 2;  // conservative

    logic [NID_FULL_W-1:0]   neuron_id_full;
    logic [NEURON_ADDR_W-1:0] neuron_id_s2;

    assign neuron_id_full = (s1_local_y * LOCAL_X_W'(TILE_W) + s1_local_x) * 2 +
                            NID_FULL_W'(s1_polarity);
    assign neuron_id_s2   = NEURON_ADDR_W'(neuron_id_full);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid  <= 1'b0;
            s2_packet <= '0;
        end else begin
            s2_valid  <= s1_valid;
            s2_packet <= {s1_tile_col, s1_tile_row,
                          s1_tile_col, s1_tile_row,
                          neuron_id_s2};
        end
    end

    // ---- Output FIFO ---------------------------------------
    logic [PACKET_W-1:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [FIFO_PTR_W:0] fifo_wr_ptr;
    logic [FIFO_PTR_W:0] fifo_rd_ptr;

    logic fifo_empty_w;
    logic overflow_r;

    assign fifo_empty_w  = (fifo_wr_ptr == fifo_rd_ptr);
    assign fifo_full_w   = (fifo_wr_ptr[FIFO_PTR_W-1:0] == fifo_rd_ptr[FIFO_PTR_W-1:0]) &&
                           (fifo_wr_ptr[FIFO_PTR_W]      != fifo_rd_ptr[FIFO_PTR_W]);
    assign fifo_overflow = overflow_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= '0;
            overflow_r  <= 1'b0;
        end else if (s2_valid) begin
            if (!fifo_full_w) begin
                fifo_mem[fifo_wr_ptr[FIFO_PTR_W-1:0]] <= s2_packet;
                fifo_wr_ptr <= fifo_wr_ptr + 1;
            end else begin
                overflow_r <= 1'b1;
            end
        end
    end

    logic pop_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_rd_ptr <= '0;
            pop_d       <= 1'b0;
        end else begin
            // Delay pop one cycle so pkt_valid/pkt_data are visible for a
            // full cycle before consumption when pkt_ready is already high.
            pop_d <= (!fifo_empty_w && pkt_ready);
            if (pop_d && !fifo_empty_w) fifo_rd_ptr <= fifo_rd_ptr + 1;
        end
    end

    assign pkt_data  = fifo_mem[fifo_rd_ptr[FIFO_PTR_W-1:0]];
    assign pkt_valid = !fifo_empty_w;

    // ---- Window advance ------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) window_start <= '0;
        else if (window_advance)
            window_start <= window_start + TIMESTAMP_W'(WINDOW_US);
    end

    // ---- Event counters ------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            events_accepted <= 32'd0;
            events_dropped  <= 32'd0;
        end else begin
            if (accept)                  events_accepted <= events_accepted + 1;
            if (dvs_valid && !in_window) events_dropped  <= events_dropped  + 1;
        end
    end

    // ---- Compile-time assertions ---------------------------
    // synthesis translate_off
    initial begin
        if (SENSOR_W % NUM_COLS != 0) begin
            $error("event_encoder: SENSOR_W=%0d not divisible by NUM_COLS=%0d", SENSOR_W, NUM_COLS);
            $finish;
        end
        if (SENSOR_H % NUM_ROWS != 0) begin
            $error("event_encoder: SENSOR_H=%0d not divisible by NUM_ROWS=%0d", SENSOR_H, NUM_ROWS);
            $finish;
        end
        if (TILE_W * TILE_H * 2 > (1 << NEURON_ADDR_W)) begin
            $error("event_encoder: TILE_W*TILE_H*2=%0d > 2^NEURON_ADDR_W=%0d. Increase NEURON_ADDR_W or reduce tile size.",
                   TILE_W*TILE_H*2, 1 << NEURON_ADDR_W);
            $finish;
        end
        if ((TILE_W * TILE_H * 2 - 1) >= (1 << NEURON_ADDR_W)) begin
            $error("event_encoder: max neuron_id=%0d exceeds NEURON_ADDR_W=%0d bits",
                   TILE_W*TILE_H*2-1, NEURON_ADDR_W);
            $finish;
        end
        $display("event_encoder OK: SENSOR=%0dx%0d TILE=%0dx%0d max_nid=%0d NEURON_ADDR_W=%0d",
                 SENSOR_W, SENSOR_H, TILE_W, TILE_H, TILE_W*TILE_H*2-1, NEURON_ADDR_W);
    end
    // synthesis translate_on

endmodule
