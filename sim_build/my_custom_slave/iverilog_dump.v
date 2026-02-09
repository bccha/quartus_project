module iverilog_dump();
initial begin
    $dumpfile("my_custom_slave.fst");
    $dumpvars(0, my_custom_slave);
end
endmodule
