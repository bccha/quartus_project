`timescale 1ns / 1ps
// Simplified behavioral model of altsyncram for Icarus Verilog
// This only implements the DUAL_PORT mode as used in dpram.v

module altsyncram (
    input  wire        clock0,
    input  wire        clock1,
    input  wire        clocken0,
    input  wire        clocken1,
    input  wire        clocken2,
    input  wire        clocken3,
    input  wire        aclr0,
    input  wire        aclr1,
    input  wire [7:0]  address_a,
    input  wire [7:0]  address_b,
    input  wire [31:0] data_a,
    input  wire [31:0] data_b,
    input  wire        wren_a,
    input  wire        wren_b,
    input  wire        rden_a,
    input  wire        rden_b,
    input  wire        addressstall_a,
    input  wire        addressstall_b,
    input  wire        byteena_a,
    input  wire        byteena_b,
    output reg  [31:0] q_a,
    output reg  [31:0] q_b,
    output wire [1:0]  eccstatus
);

    parameter address_aclr_b = "NONE";
    parameter address_reg_b = "CLOCK0";
    parameter clock_enable_input_a = "BYPASS";
    parameter clock_enable_input_b = "BYPASS";
    parameter clock_enable_output_b = "BYPASS";
    parameter intended_device_family = "Cyclone V";
    parameter lpm_type = "altsyncram";
    parameter numwords_a = 256;
    parameter numwords_b = 256;
    parameter operation_mode = "DUAL_PORT";
    parameter outdata_aclr_b = "NONE";
    parameter outdata_reg_b = "UNREGISTERED";
    parameter power_up_uninitialized = "FALSE";
    parameter read_during_write_mode_mixed_ports = "DONT_CARE";
    parameter widthad_a = 8;
    parameter widthad_b = 8;
    parameter width_a = 32;
    parameter width_b = 32;
    parameter width_byteena_a = 1;

    reg [31:0] mem [0:255];

    // Port A: Write
    always @(posedge clock0) begin
        if (wren_a) begin
            mem[address_a] <= data_a;
        end
    end

    // Port B: Read
    always @(posedge clock0) begin
        q_b <= mem[address_b];
    end

    assign eccstatus = 2'b00;

endmodule
