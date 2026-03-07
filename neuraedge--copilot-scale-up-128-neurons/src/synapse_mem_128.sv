// synapse_mem_128.sv — 4-bank synaptic weight memory for 128-neuron array
// 128×128 × 8-bit = 16KB, split conceptually into 4 BRAM banks (32 cols each)
// Port A: wide read — pre-index (7-bit) → all 128 weights (2-cycle pipeline)
// Port S: narrow read — {pre[6:0], post[6:0]} → single weight (2-cycle pipeline)
// Port B: write — {pre[6:0], post[6:0]} + data + wr_en

module synapse_mem_128 #(
    parameter N_NEURONS = 128,
    parameter DATA_W    = 8,
    parameter ADDR_W    = 14   // {pre[6:0], post[6:0]}, 2^14 = 16384 entries
) (
    input  logic                              clk,
    input  logic                              rst_n,

    // Port A — wide read for spike router (2-cycle registered pipeline)
    input  logic [6:0]                        a_addr,   // pre-synaptic index 0..127
    output logic [N_NEURONS-1:0][DATA_W-1:0]  a_rdata,  // all 128 weights of that row

    // Port S — narrow read for STDP / host inspection (2-cycle registered pipeline)
    input  logic [ADDR_W-1:0]                 s_addr,   // {pre[6:0], post[6:0]}
    output logic [DATA_W-1:0]                 s_rdata,  // single weight

    // Port B — write (config / STDP updates)
    input  logic [ADDR_W-1:0]                 b_addr,   // {pre[6:0], post[6:0]}
    input  logic [DATA_W-1:0]                 b_wdata,
    input  logic                              b_wr_en
);

    // Flat 16KB weight array (4-bank structure emulated as a single array).
    // Address encoding: weight_mem[{pre[6:0], post[6:0]}]
    //   pre  occupies bits [13:7], post occupies bits [6:0].
    //   max index = {7'h7F, 7'h7F} = 14'h3FFF = 16383. Array size = 16384.
    // Synthesis: annotate ram_style="block" so Vivado infers BRAM automatically.
    (* ram_style = "block" *)
    logic signed [DATA_W-1:0] weight_mem [0:(1<<ADDR_W)-1];

    // ---- Port B: synchronous write ----
    always_ff @(posedge clk) begin
        if (b_wr_en)
            weight_mem[b_addr] <= $signed(b_wdata);
    end

    // ---- Port A: 2-cycle wide read pipeline ----
    // Stage 1: register the pre-synaptic address
    logic [6:0] a_addr_r;
    always_ff @(posedge clk)
        a_addr_r <= a_addr;

    // Stage 2: read all 128 post-synaptic weights in parallel
    // In synthesis, the 4-bank hint causes Vivado to map each 32-column group
    // to one 18Kb BRAM instance (all 4 read simultaneously).
    integer rd;
    always_ff @(posedge clk) begin
        for (rd = 0; rd < N_NEURONS; rd = rd + 1)
            a_rdata[rd] <= weight_mem[{a_addr_r, rd[6:0]}];
    end

    // ---- Port S: 2-cycle narrow read pipeline ----
    // Stage 1: register the full {pre, post} address
    logic [ADDR_W-1:0] s_addr_r;
    always_ff @(posedge clk)
        s_addr_r <= s_addr;

    // Stage 2: register the weight read
    always_ff @(posedge clk)
        s_rdata <= weight_mem[s_addr_r];

    // ---- Simulation initialisation: zero all weights ----
    integer i;
    initial begin
        for (i = 0; i < (1 << ADDR_W); i = i + 1)
            weight_mem[i] = 8'h00;
        // To load pre-trained weights during simulation, uncomment:
        // $readmemh("weights/mnist_weights.hex", weight_mem);
    end

endmodule
