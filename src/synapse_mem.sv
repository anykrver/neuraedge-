// synapse_mem.sv — Dual-port Block RAM: 32×32 weight matrix (1 KB)
// Each weight is a signed 8-bit Q2.6 value.
// Port A: read port (spike router); Port B: write port (config / STDP).

module synapse_mem #(
    parameter N_NEURONS = 32,
    parameter DATA_W    = 8,
    parameter ADDR_W    = 10  // log2(32*32) = 10
) (
    input  logic             clk,
    input  logic             rst_n,

    // Port A — read (1-cycle latency)
    input  logic [ADDR_W-1:0] a_addr,   // {src[4:0], dst[4:0]}
    output logic [DATA_W-1:0] a_rdata,  // weight read out

    // Port B — write
    input  logic [ADDR_W-1:0] b_addr,
    input  logic [DATA_W-1:0] b_wdata,
    input  logic              b_wr_en
);

    // Vivado BRAM inference attribute
    (* ram_style = "block" *)
    logic signed [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];

    // Port A: synchronous read
    always_ff @(posedge clk) begin
        a_rdata <= mem[a_addr];
    end

    // Port B: synchronous write
    always_ff @(posedge clk) begin
        if (b_wr_en)
            mem[b_addr] <= $signed(b_wdata);
    end

    // Simulation-only: load weights from hex file if present
    // In synthesis this block is ignored.
    initial begin
        integer i;
        for (i = 0; i < (1<<ADDR_W); i = i + 1)
            mem[i] = 8'h00;
        // Uncomment to load weights:
        // $readmemh("weights.hex", mem);
    end

endmodule
