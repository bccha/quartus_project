module my_custom_slave (
    input  wire        clk,
    input  wire        reset_n,
    input  wire [7:0]  address,
    input  wire        write,
    input  wire [31:0] writedata,
    input  wire        read,
    output wire [31:0] readdata,   // wire 타입으로 변경 (dpram 출력 연결)
    output reg         readdatavalid // [추가] Read Data Valid 신호
);
    
    dpram dpram_inst (
        .clock(clk),        
        .rdaddress(address),
        .wraddress(address),
        .wren(write),
        .data(writedata),        
        .q(readdata)        
    );
   
    // 읽기와 쓰기를 하나의 블록에서 처리 (동기식)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin            
            readdatavalid <= 1'b0;
        end else begin           
            readdatavalid <= read;
        end
    end

endmodule