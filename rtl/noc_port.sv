// noc_port.sv
// Credit-based NoC link interface (data + valid + credit).
// Author: Rahul Verma | Apache 2.0
`timescale 1ns / 1ps

interface noc_port #(
    parameter int PW = 10   // packet width; overridden at instantiation
)(
    input logic clk,
    input logic rst_n
);

    logic [PW-1:0] data;    // packet payload — driven by sender
    logic          valid;   // packet present  — driven by sender
    logic          credit;  // FIFO slot free  — driven by receiver

    // ---- Sender modport: router output side ----------------
    modport sender_mp (
        input  clk, rst_n,
        output data,
        output valid,
        input  credit
    );

    // ---- Receiver modport: router input side ---------------
    modport receiver_mp (
        input  clk, rst_n,
        input  data,
        input  valid,
        output credit
    );

    // ---- Passive modport: monitor / assertions only --------
    modport monitor_mp (
        input clk, rst_n,
        input data, valid, credit
    );

    // ===========================================================
    // SVA: link protocol invariants
    // ===========================================================
    // synthesis translate_off
`ifdef SVA_ENABLE

    // 1. valid must not be asserted when credit is 0
    //    (sender MUST check credit before asserting valid)
    property p_no_send_without_credit;
        @(posedge clk) disable iff (!rst_n)
        valid |-> credit;
    endproperty
    a_no_send_without_credit: assert property (p_no_send_without_credit)
        else $error("[noc_port] PROTOCOL: valid asserted with credit=0. Sender ignored backpressure.");

    // 2. data must be stable while valid is high (one-cycle pulse, data held)
    property p_data_stable_when_valid;
        @(posedge clk) disable iff (!rst_n)
        (valid && !$stable(valid)) |-> ##1 !valid;  // valid is a 1-cycle strobe
    endproperty
    a_data_stable_when_valid: assert property (p_data_stable_when_valid)
        else $warning("[noc_port] valid held high for >1 cycle — check router output logic.");

    // 3. credit is never X or Z during normal operation
    property p_credit_known;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(credit);
    endproperty
    a_credit_known: assert property (p_credit_known)
        else $error("[noc_port] credit is X/Z — receiver not driving credit output.");

    // 4. valid is never X or Z during normal operation
    property p_valid_known;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(valid);
    endproperty
    a_valid_known: assert property (p_valid_known)
        else $error("[noc_port] valid is X/Z — sender not driving valid output.");

`endif
    // synthesis translate_on

endinterface : noc_port
