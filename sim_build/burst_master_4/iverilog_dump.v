module iverilog_dump();
initial begin
    $dumpfile("burst_master_4.fst");
    $dumpvars(0, burst_master_4);
end
endmodule
