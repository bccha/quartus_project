module iverilog_dump();
initial begin
    $dumpfile("burst_master.fst");
    $dumpvars(0, burst_master);
end
endmodule
