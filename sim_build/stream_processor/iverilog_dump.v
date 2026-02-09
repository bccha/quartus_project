module iverilog_dump();
initial begin
    $dumpfile("stream_processor.fst");
    $dumpvars(0, stream_processor);
end
endmodule
