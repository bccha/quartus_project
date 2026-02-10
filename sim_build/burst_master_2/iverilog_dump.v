module iverilog_dump();
initial begin
    $dumpfile("burst_master_2.fst");
    $dumpvars(0, burst_master_2);
end
endmodule
