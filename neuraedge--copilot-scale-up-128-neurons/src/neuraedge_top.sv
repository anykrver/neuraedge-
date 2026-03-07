// neuraedge_top.sv — Basys 3 FPGA wrapper for NeuraEdge chip
// Board: Digilent Basys 3 (Artix-7 xc7a35tcpg236-1), 100 MHz

module neuraedge_top (
    input  logic        CLK100MHZ,
    input  logic        BTNC,   // reset (active high)
    input  logic        BTNR,   // run inference
    input  logic        BTNL,
    input  logic        BTNU,
    input  logic        BTND,
    input  logic [15:0] SW,
    output logic [15:0] LED,
    output logic [6:0]  SEG,    // segments a-g (active low on Basys3)
    output logic [3:0]  AN      // digit anodes (active low)
);

    // ---- Clock / reset ----
    logic clk;
    logic rst_n;
    assign clk  = CLK100MHZ;

    // ---- Button debouncer (~10ms at 100 MHz = 1_000_000 cycles) ----
    localparam DEBOUNCE_CYCLES = 1_000_000;
    localparam DB_W = 20;

    logic [DB_W-1:0] db_cnt_c, db_cnt_r;
    logic db_btnc_d, db_btnr_d;

    // Debounce BTNC (reset)
    always_ff @(posedge clk) begin
        if (BTNC == db_btnc_d) begin
            if (db_cnt_c == DEBOUNCE_CYCLES-1) db_cnt_c <= db_cnt_c;
            else db_cnt_c <= db_cnt_c + 1;
        end else begin
            db_cnt_c  <= '0;
            db_btnc_d <= BTNC;
        end
    end
    logic btnc_clean;
    always_ff @(posedge clk)
        if (db_cnt_c == DEBOUNCE_CYCLES-1) btnc_clean <= db_btnc_d;

    // Debounce BTNR (run)
    always_ff @(posedge clk) begin
        if (BTNR == db_btnr_d) begin
            if (db_cnt_r == DEBOUNCE_CYCLES-1) db_cnt_r <= db_cnt_r;
            else db_cnt_r <= db_cnt_r + 1;
        end else begin
            db_cnt_r  <= '0;
            db_btnr_d <= BTNR;
        end
    end
    logic btnr_clean;
    always_ff @(posedge clk)
        if (db_cnt_r == DEBOUNCE_CYCLES-1) btnr_clean <= db_btnr_d;

    // Edge detect for run pulse
    logic btnr_prev, run_pulse;
    always_ff @(posedge clk) btnr_prev <= btnr_clean;
    assign run_pulse = btnr_clean & ~btnr_prev;

    // Synchronous active-low reset
    assign rst_n = ~btnc_clean;

    // ---- XOR network weight loading FSM ----
    // Redesigned topology — N4 driven directly from both inputs:
    //   N0→N3: +1.0 (0x40)  N1→N3: +1.0 (0x40)  (OR hidden: fires on any input)
    //   N0→N4: +0.5 (0x20)  N1→N4: +0.5 (0x20)  (fires only when BOTH active)
    //   N3→N5: +1.2 (0x4D)  N4→N5: -2.0 (0x80)  (net=-0.8 when both → N5 silent)

    typedef enum logic [3:0] {
        WL_IDLE = 4'd0,
        WL_W0   = 4'd1,  // N0→N3: +1.0
        WL_W1   = 4'd2,  // N1→N3: +1.0
        WL_W2   = 4'd3,  // N0→N4: +0.5
        WL_W3   = 4'd4,  // N1→N4: +0.5
        WL_W4   = 4'd5,  // N3→N5: +1.2
        WL_W5   = 4'd6,  // N4→N5: -2.0
        WL_DONE = 4'd7
    } wl_state_t;

    wl_state_t wl_state;
    logic       cfg_weight_wr;
    logic [9:0] cfg_weight_addr;
    logic [7:0] cfg_weight_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wl_state       <= WL_W0;  // auto-load on reset
            cfg_weight_wr  <= 1'b0;
            cfg_weight_addr<= '0;
            cfg_weight_data<= '0;
        end else begin
            cfg_weight_wr <= 1'b0;  // default: no write

            case (wl_state)
                WL_IDLE: ; // wait

                WL_W0: begin  // N0→N3: addr={0,3}=3, +1.0=0x40
                    cfg_weight_addr <= {5'd0, 5'd3};
                    cfg_weight_data <= 8'h40;
                    cfg_weight_wr   <= 1'b1;
                    wl_state        <= WL_W1;
                end
                WL_W1: begin  // N1→N3: +1.0=0x40
                    cfg_weight_addr <= {5'd1, 5'd3};
                    cfg_weight_data <= 8'h40;
                    cfg_weight_wr   <= 1'b1;
                    wl_state        <= WL_W2;
                end
                WL_W2: begin  // N0→N4: +0.5=0x20
                    cfg_weight_addr <= {5'd0, 5'd4};
                    cfg_weight_data <= 8'h20;
                    cfg_weight_wr   <= 1'b1;
                    wl_state        <= WL_W3;
                end
                WL_W3: begin  // N1→N4: +0.5=0x20
                    cfg_weight_addr <= {5'd1, 5'd4};
                    cfg_weight_data <= 8'h20;
                    cfg_weight_wr   <= 1'b1;
                    wl_state        <= WL_W4;
                end
                WL_W4: begin  // N3→N5: +1.2=0x4D
                    cfg_weight_addr <= {5'd3, 5'd5};
                    cfg_weight_data <= 8'h4D;
                    cfg_weight_wr   <= 1'b1;
                    wl_state        <= WL_W5;
                end
                WL_W5: begin  // N4→N5: -2.0=0x80 (signed -128 in Q2.6)
                    cfg_weight_addr <= {5'd4, 5'd5};
                    cfg_weight_data <= 8'h80;
                    cfg_weight_wr   <= 1'b1;
                    wl_state        <= WL_DONE;
                end
                WL_DONE: ; // weights loaded, stay here

                default: wl_state <= WL_IDLE;
            endcase
        end
    end

    // ---- Inputs from switches ----
    logic [7:0] inp_x1, inp_x2;
    assign inp_x1 = SW[0] ? 8'hFF : 8'h00;  // SW[0]=x1
    assign inp_x2 = SW[1] ? 8'hFF : 8'h00;  // SW[1]=x2

    logic [7:0] cfg_input [0:1];
    assign cfg_input[0] = inp_x1;
    assign cfg_input[1] = inp_x2;

    // ---- Core instantiation ----
    logic        out_done;
    logic [15:0] out_timestep;
    logic [7:0]  out_spike_count [0:31];
    logic [31:0] out_spike_vector;

    neuraedge #(.N_NEURONS(32), .N_INPUTS(2)) u_core (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_run          (run_pulse),
        .cfg_t_max        (16'd150),
        .cfg_weight_wr    (cfg_weight_wr),
        .cfg_weight_addr  (cfg_weight_addr),
        .cfg_weight_data  (cfg_weight_data),
        .cfg_input        (cfg_input),
        .cfg_encode_mode  (SW[2]),
        .cfg_stdp_enable  (SW[3]),
        .out_done         (out_done),
        .out_timestep     (out_timestep),
        .out_spike_count  (out_spike_count),
        .out_spike_vector (out_spike_vector)
    );

    // ---- LED outputs ----
    // LED[6]: heartbeat (~1 Hz)
    logic [26:0] hb_cnt;
    logic hb_led;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hb_cnt <= '0;
            hb_led <= 1'b0;
        end else if (hb_cnt == 27'd49_999_999) begin
            hb_cnt <= '0;
            hb_led <= ~hb_led;
        end else begin
            hb_cnt <= hb_cnt + 1;
        end
    end

    // XOR result: spike_count[5] > threshold (e.g. 5 spikes)
    logic xor_result;
    assign xor_result = (out_spike_count[5] > 8'd5);

    assign LED[0]  = out_done;
    assign LED[1]  = xor_result;
    assign LED[2]  = |out_spike_count[2];
    assign LED[3]  = |out_spike_count[3];
    assign LED[4]  = |out_spike_count[4];
    assign LED[5]  = |out_spike_count[5];
    assign LED[6]  = hb_led;
    assign LED[7]  = SW[3] & out_done;  // STDP active indicator
    assign LED[15:8] = 8'h00;

    // ---- 7-segment display: show spike count of neuron 5 (XOR output) ----
    // Simple 4-digit multiplexer at ~1 kHz refresh
    logic [1:0]  digit_sel;
    logic [16:0] seg_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_cnt   <= '0;
            digit_sel <= 2'd0;
        end else if (seg_cnt == 17'd99_999) begin
            seg_cnt   <= '0;
            digit_sel <= digit_sel + 1;
        end else begin
            seg_cnt <= seg_cnt + 1;
        end
    end

    logic [3:0] bcd_digit;
    always_comb begin
        case (digit_sel)
            2'd0: bcd_digit = out_spike_count[5][3:0];   // ones
            2'd1: bcd_digit = out_spike_count[5][7:4];   // tens (approx)
            2'd2: bcd_digit = out_spike_count[4][3:0];
            2'd3: bcd_digit = out_spike_count[2][3:0];
            default: bcd_digit = 4'h0;
        endcase
    end

    // 7-segment decoder (active low, segments: gfedcba)
    always_comb begin
        case (bcd_digit)
            4'h0: SEG = 7'b1000000;
            4'h1: SEG = 7'b1111001;
            4'h2: SEG = 7'b0100100;
            4'h3: SEG = 7'b0110000;
            4'h4: SEG = 7'b0011001;
            4'h5: SEG = 7'b0010010;
            4'h6: SEG = 7'b0000010;
            4'h7: SEG = 7'b1111000;
            4'h8: SEG = 7'b0000000;
            4'h9: SEG = 7'b0010000;
            4'hA: SEG = 7'b0001000;
            4'hB: SEG = 7'b0000011;
            4'hC: SEG = 7'b1000110;
            4'hD: SEG = 7'b0100001;
            4'hE: SEG = 7'b0000110;
            4'hF: SEG = 7'b0001110;
        endcase
    end

    // Digit anode select (active low)
    always_comb begin
        case (digit_sel)
            2'd0: AN = 4'b1110;
            2'd1: AN = 4'b1101;
            2'd2: AN = 4'b1011;
            2'd3: AN = 4'b0111;
            default: AN = 4'b1111;
        endcase
    end

endmodule
