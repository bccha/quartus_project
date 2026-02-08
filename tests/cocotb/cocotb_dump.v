`timescale 1ns / 1ps
module cocotb_dump();
initial begin
    $dumpfile("waveform.vcd");
    $dumpvars(0);
end
endmodule
