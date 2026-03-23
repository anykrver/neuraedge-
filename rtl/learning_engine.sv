// ============================================================
// Module:      learning_engine
// Description: Trace-based STDP weight update engine.
//
// Change log:
//   v1.0 — initial release
//   v1.1 — BUG-9 fix: off-by-one in scan FSM (last synapse dropped)
//         — BUG-10 fix: q_empty/q_full count-based, correct for any depth
//   v1.3 — FIX L3: q_delta sign fix; event qualification timing hardening
//   v2.0 — Converted to SystemVerilog (.sv).
//   v2.1 — Added explicit 3-stage weight-update pipeline:
//            P0 (ST_SCAN_RD): issue BRAM read request
//            P1 (ST_SCAN_WR): receive BRAM data, compute new weight
//            P2 (new ST_SCAN_COMMIT): register computed weight, issue write
//            Separates the sat_add arithmetic from the BRAM write-back
//            path, reducing the critical path by one full adder chain.
//            STDP scan latency increases by 1 cycle per synapse (negligible
//            at 512 synapses vs 100 MHz). No functional change.
//
// Author:   NeuraEdge / Rahul Verma | Version: 2.0.0 | Apache 2.0
// ============================================================
`timescale 1ns / 1ps

module learning_engine #(
    parameter int NUM_NEURONS   = 64,
    parameter int NUM_SYNAPSES  = 512,
    parameter int WEIGHT_W      = 8,
    parameter int TRACE_W       = 8,
    parameter int TRACE_INCR    = 16,
    parameter int TRACE_DECAY   = 3,
    parameter int A_PLUS        = 4,
    parameter int A_MINUS       = 2,
    parameter int MAX_WEIGHT    = 255,
    parameter int MIN_WEIGHT    = 0,
    parameter int SPIKE_QUEUE_D = 2
)(
    input  logic clk,
    input  logic rst_n,

    input  logic [NUM_NEURONS-1:0]  pre_spike,
    input  logic [NUM_NEURONS-1:0]  post_spike,
    input  logic                    spikes_valid,

    output logic [$clog2(NUM_NEURONS)-1:0]  mem_wr_neuron,
    output logic [$clog2(NUM_SYNAPSES)-1:0] mem_wr_syn,
    output logic [WEIGHT_W-1:0]             mem_wr_data,
    output logic                            mem_we,

    output logic [$clog2(NUM_NEURONS)-1:0]  mem_rd_neuron,
    output logic [$clog2(NUM_SYNAPSES)-1:0] mem_rd_syn,
    input  logic [WEIGHT_W-1:0]             mem_rd_data,
    input  logic                            mem_rd_valid,

    output logic [31:0]  ltp_count,
    output logic [31:0]  ltd_count,
    output logic         scan_active
);

    // Reset fanout hardening: pipeline rst_n one cycle to localise fanout
    // into large trace/FSM arrays and give placer/router a register boundary.
    logic rst_n_pipe;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_n_pipe <= 1'b0;
        else        rst_n_pipe <= 1'b1;
    end

    localparam int NEURON_W = $clog2(NUM_NEURONS);
    localparam int SYN_W    = $clog2(NUM_SYNAPSES);
    localparam int Q_CNT_W  = $clog2(SPIKE_QUEUE_D + 1);  // FIX BUG-10

    localparam logic EVTYPE_LTP = 1'b1;
    localparam logic EVTYPE_LTD = 1'b0;

    // ---- Eligibility traces --------------------------------
    logic [TRACE_W-1:0] pre_trace  [0:NUM_NEURONS-1];
    logic [TRACE_W-1:0] post_trace [0:NUM_NEURONS-1];

    // ---- Spike queue ---------------------------------------
    logic [NEURON_W-1:0]          q_neuron [0:SPIKE_QUEUE_D-1];
    logic [TRACE_W-1:0]           q_trace  [0:SPIKE_QUEUE_D-1];
    logic                         q_type   [0:SPIKE_QUEUE_D-1];

    logic [$clog2(SPIKE_QUEUE_D)-1:0] q_wr_ptr;
    logic [$clog2(SPIKE_QUEUE_D)-1:0] q_rd_ptr;
    logic [Q_CNT_W-1:0]               q_count;

    logic q_empty, q_full;
    assign q_empty = (q_count == '0);
    assign q_full  = (q_count == Q_CNT_W'(SPIKE_QUEUE_D));

    // ---- Scan FSM state encoding ---------------------------
    typedef enum logic [2:0] {
        ST_IDLE        = 3'd0,
        ST_SCAN_RD     = 3'd1,
        ST_SCAN_WR     = 3'd2,
        ST_SCAN_COMMIT = 3'd3   // P2: register computed delta, assert mem_we
    } fsm_t;

    fsm_t              state;
    logic [NEURON_W-1:0] scan_neuron;
    logic [SYN_W-1:0]    scan_syn;
    logic [TRACE_W-1:0]  scan_trace;
    logic                scan_type;

    // ---- Pipeline stage registers --------------------------
    logic                 pipe_valid;
    logic [NEURON_W-1:0]  pipe_neuron;
    logic [SYN_W-1:0]     pipe_syn;
    logic [TRACE_W-1:0]   pipe_trace;
    logic                 pipe_type;
    logic                 pipe_last_syn;

    // P1 compute registers (ST_SCAN_WR output)
    logic                 p1_valid;
    logic [NEURON_W-1:0]  p1_neuron;
    logic [SYN_W-1:0]     p1_syn;
    logic [WEIGHT_W-1:0]  p1_weight;    // sat_add result
    logic                 p1_last_syn;

    // P2 commit registers (ST_SCAN_COMMIT — drives mem_we)
    logic                 wr_pending;
    logic [NEURON_W-1:0]  wr_neuron_r;
    logic [SYN_W-1:0]     wr_syn_r;
    logic [WEIGHT_W-1:0]  wr_data_r;

    // Pending event latch
    logic                 ev_pending;
    logic [NEURON_W-1:0]  ev_neuron;
    logic [TRACE_W-1:0]   ev_trace;
    logic                 ev_type;

    logic will_dequeue_idle;
    logic q_can_enqueue;
    logic enq_from_pending;
    logic enq_from_gen;
    assign will_dequeue_idle = (state == ST_IDLE) && !q_empty;
    assign q_can_enqueue     = !q_full || will_dequeue_idle;
    assign enq_from_pending  = ev_pending && q_can_enqueue;
    assign enq_from_gen      = !ev_pending && ev_gen_valid_r && q_can_enqueue;
    assign scan_active       = (state != ST_IDLE) || ev_pending || ev_gen_valid_r || (q_count != '0);

    // ---- Priority encoder ----------------------------------
    function automatic logic [NEURON_W:0] first_set(
        input logic [NUM_NEURONS-1:0] vec
    );
        first_set = '0;
        for (int k = NUM_NEURONS-1; k >= 0; k--)
            if (vec[k]) first_set = {1'b1, NEURON_W'(k)};
    endfunction

    // ---- Saturating weight delta ---------------------------
    function automatic logic [WEIGHT_W-1:0] sat_add(
        input logic [WEIGHT_W-1:0] w, delta,
        input logic                add
    );
        logic [WEIGHT_W:0] r;
        if (add) begin
            r       = {1'b0, w} + {1'b0, delta};
            sat_add = r[WEIGHT_W]                              ? WEIGHT_W'(MAX_WEIGHT)
                    : (r[WEIGHT_W-1:0] > WEIGHT_W'(MAX_WEIGHT)) ? WEIGHT_W'(MAX_WEIGHT)
                    :  r[WEIGHT_W-1:0];
        end else begin
            sat_add = (delta >= w) ? WEIGHT_W'(MIN_WEIGHT) : w - delta;
        end
    endfunction

    // ---- Combinational event extraction --------------------
    logic [NEURON_W:0] post_hit_w, pre_hit_w;
    logic post_evt_w, pre_evt_w, ev_gen_valid_w;
    logic [NEURON_W-1:0] ev_gen_neuron_w;
    logic [TRACE_W-1:0]  ev_gen_trace_w;
    logic                ev_gen_type_w;
    logic                ev_gen_valid_r;
    logic [NEURON_W-1:0] ev_gen_neuron_r;
    logic [TRACE_W-1:0]  ev_gen_trace_r;
    logic                ev_gen_type_r;

    assign post_hit_w      = first_set(post_spike);
    assign pre_hit_w       = first_set(pre_spike);
    assign post_evt_w      = post_hit_w[NEURON_W] && (pre_trace [post_hit_w[NEURON_W-1:0]] > '0);
    assign pre_evt_w       = pre_hit_w [NEURON_W]
                           && (post_trace[pre_hit_w [NEURON_W-1:0]] > '0)
                           && (pre_trace [pre_hit_w [NEURON_W-1:0]] == '0);
    assign ev_gen_valid_w  = spikes_valid && (post_evt_w || pre_evt_w);
    assign ev_gen_neuron_w = post_evt_w ? post_hit_w[NEURON_W-1:0] : pre_hit_w[NEURON_W-1:0];
    assign ev_gen_trace_w  = post_evt_w ? pre_trace [post_hit_w[NEURON_W-1:0]]
                                        : post_trace[pre_hit_w [NEURON_W-1:0]];
    assign ev_gen_type_w   = post_evt_w ? EVTYPE_LTP : EVTYPE_LTD;

    logic do_dequeue;
    assign do_dequeue = will_dequeue_idle;

    always_ff @(posedge clk) begin
        if (!rst_n_pipe) begin
            for (int n = 0; n < NUM_NEURONS; n++) begin
                pre_trace [n] <= '0;
                post_trace[n] <= '0;
            end
            q_wr_ptr    <= '0;
            q_rd_ptr    <= '0;
            q_count     <= '0;
            state       <= ST_IDLE;
            scan_neuron <= '0;
            scan_syn    <= '0;
            scan_trace  <= '0;
            scan_type   <= EVTYPE_LTP;
            pipe_valid    <= 1'b0;
            pipe_last_syn <= 1'b0;
            p1_valid      <= 1'b0;
            p1_neuron     <= '0;
            p1_syn        <= '0;
            p1_weight     <= '0;
            p1_last_syn   <= 1'b0;
            wr_pending    <= 1'b0;
            wr_neuron_r   <= '0;
            wr_syn_r      <= '0;
            wr_data_r     <= '0;
            ev_pending  <= 1'b0;
            ev_neuron   <= '0;
            ev_trace    <= '0;
            ev_type     <= EVTYPE_LTP;
            ev_gen_valid_r  <= 1'b0;
            ev_gen_neuron_r <= '0;
            ev_gen_trace_r  <= '0;
            ev_gen_type_r   <= EVTYPE_LTP;
            mem_we      <= 1'b0;
            mem_wr_neuron <= '0;
            mem_wr_syn    <= '0;
            mem_wr_data   <= '0;
            mem_rd_neuron <= '0;
            mem_rd_syn    <= '0;
            ltp_count   <= 32'd0;
            ltd_count   <= 32'd0;
        end else begin

            // 1. Leak all traces
            for (int n = 0; n < NUM_NEURONS; n++) begin
                pre_trace [n] <= pre_trace [n] - (pre_trace [n] >> TRACE_DECAY);
                post_trace[n] <= post_trace[n] - (post_trace[n] >> TRACE_DECAY);
            end

            // 2. Bump traces on spikes
            if (spikes_valid) begin
                for (int n = 0; n < NUM_NEURONS; n++) begin
                    if (pre_spike[n])
                        pre_trace[n] <= (pre_trace[n] > ({TRACE_W{1'b1}} - TRACE_W'(TRACE_INCR)))
                                        ? {TRACE_W{1'b1}}
                                        : (pre_trace[n] - (pre_trace[n] >> TRACE_DECAY)
                                           + TRACE_W'(TRACE_INCR));
                    if (post_spike[n])
                        post_trace[n] <= (post_trace[n] > ({TRACE_W{1'b1}} - TRACE_W'(TRACE_INCR)))
                                         ? {TRACE_W{1'b1}}
                                         : (post_trace[n] - (post_trace[n] >> TRACE_DECAY)
                                            + TRACE_W'(TRACE_INCR));
                end
            end

            // 3. Pipeline event extraction before enqueue (timing closure)
            ev_gen_valid_r  <= ev_gen_valid_w;
            ev_gen_neuron_r <= ev_gen_neuron_w;
            ev_gen_trace_r  <= ev_gen_trace_w;
            ev_gen_type_r   <= ev_gen_type_w;

            // 4. Enqueue STDP events
            if (enq_from_pending) begin
                q_neuron[q_wr_ptr] <= ev_neuron;
                q_trace [q_wr_ptr] <= ev_trace;
                q_type  [q_wr_ptr] <= ev_type;
                q_wr_ptr           <= q_wr_ptr + 1;
                if (ev_type == EVTYPE_LTP) ltp_count <= ltp_count + 1;
                else                        ltd_count <= ltd_count + 1;
                if (ev_gen_valid_r) begin
                    ev_pending <= 1'b1;
                    ev_neuron  <= ev_gen_neuron_r;
                    ev_trace   <= ev_gen_trace_r;
                    ev_type    <= ev_gen_type_r;
                end else begin
                    ev_pending <= 1'b0;
                end
            end else if (enq_from_gen) begin
                q_neuron[q_wr_ptr] <= ev_gen_neuron_r;
                q_trace [q_wr_ptr] <= ev_gen_trace_r;
                q_type  [q_wr_ptr] <= ev_gen_type_r;
                q_wr_ptr           <= q_wr_ptr + 1;
                if (ev_gen_type_r == EVTYPE_LTP) ltp_count <= ltp_count + 1;
                else                              ltd_count <= ltd_count + 1;
            end else if (!ev_pending && ev_gen_valid_r) begin
                ev_pending <= 1'b1;
                ev_neuron  <= ev_gen_neuron_r;
                ev_trace   <= ev_gen_trace_r;
                ev_type    <= ev_gen_type_r;
            end

            // 5. Scan FSM — drive memory writes from retimed registers
            mem_we        <= wr_pending;
            mem_wr_neuron <= wr_neuron_r;
            mem_wr_syn    <= wr_syn_r;
            mem_wr_data   <= wr_data_r;
            wr_pending    <= 1'b0;

            unique case (state)

                ST_IDLE: begin
                    pipe_valid    <= 1'b0;
                    pipe_last_syn <= 1'b0;
                    if (!q_empty) begin
                        scan_neuron <= q_neuron[q_rd_ptr];
                        scan_trace  <= q_trace [q_rd_ptr];
                        scan_type   <= q_type  [q_rd_ptr];
                        scan_syn    <= '0;
                        q_rd_ptr    <= q_rd_ptr + 1;
                        state       <= ST_SCAN_RD;
                    end
                end

                // FIX BUG-9: ST_SCAN_RD always goes to ST_SCAN_WR.
                // Last-synapse flag passed so ST_SCAN_WR knows to return to idle.
                ST_SCAN_RD: begin
                    mem_rd_neuron <= scan_neuron;
                    mem_rd_syn    <= scan_syn;
                    pipe_valid    <= 1'b1;
                    pipe_neuron   <= scan_neuron;
                    pipe_syn      <= scan_syn;
                    pipe_trace    <= scan_trace;
                    pipe_type     <= scan_type;
                    pipe_last_syn <= (scan_syn == SYN_W'(NUM_SYNAPSES - 1));
                    scan_syn      <= scan_syn + 1;
                    state         <= ST_SCAN_WR;
                end

                // P1: receive BRAM data, compute new weight via sat_add
                ST_SCAN_WR: begin
                    p1_valid   <= pipe_valid && mem_rd_valid;
                    p1_neuron  <= pipe_neuron;
                    p1_syn     <= pipe_syn;
                    p1_last_syn<= pipe_last_syn;
                    if (pipe_valid && mem_rd_valid) begin
                        p1_weight <= sat_add(
                            mem_rd_data,
                            pipe_type == EVTYPE_LTP ? WEIGHT_W'(A_PLUS) : WEIGHT_W'(A_MINUS),
                            pipe_type == EVTYPE_LTP
                        );
                    end

                    if (pipe_last_syn) begin
                        pipe_valid    <= 1'b0;
                        pipe_last_syn <= 1'b0;
                    end else begin
                        // Issue next BRAM read while P1 is computing
                        mem_rd_neuron <= scan_neuron;
                        mem_rd_syn    <= scan_syn;
                        pipe_valid    <= 1'b1;
                        pipe_neuron   <= scan_neuron;
                        pipe_syn      <= scan_syn;
                        pipe_trace    <= scan_trace;
                        pipe_type     <= scan_type;
                        pipe_last_syn <= (scan_syn == SYN_W'(NUM_SYNAPSES - 1));
                        scan_syn      <= scan_syn + 1;
                    end
                    state <= ST_SCAN_COMMIT;
                end

                // P2: register computed weight and assert write-enable
                ST_SCAN_COMMIT: begin
                    wr_pending  <= p1_valid;
                    wr_neuron_r <= p1_neuron;
                    wr_syn_r    <= p1_syn;
                    wr_data_r   <= p1_weight;

                    if (p1_last_syn) begin
                        state <= ST_IDLE;
                    end else begin
                        state <= ST_SCAN_WR;
                    end
                end

                default: state <= ST_IDLE;

            endcase

            // q_count net-delta — one NBA, no race (FIX BUG-10)
            q_count <= q_count
                     + ((enq_from_pending || enq_from_gen) ? Q_CNT_W'(1) : '0)
                     - (do_dequeue ? Q_CNT_W'(1) : '0);

        end
    end

    // synthesis translate_off
    task automatic dump_traces();
        $display("=== Eligibility traces ===");
        for (int k = 0; k < NUM_NEURONS; k++)
            if (pre_trace[k] > '0 || post_trace[k] > '0)
                $display("  n[%0d]: pre=%0d post=%0d", k, pre_trace[k], post_trace[k]);
    endtask
    // synthesis translate_on

endmodule
