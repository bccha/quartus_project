module my_div (
    input clk,
    input reset,
    input clk_en,
    input [31:0] dataa,
    input [31:0] datab,
    output reg [31:0] result
);

    /* 이 파일을 고치면 qsys generate를 해야 함 */
    reg [63:0] mult_stage; 

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            mult_stage <= 0;
            result <= 0;
        end 
        else if (clk_en) begin
            // [Cycle 1] 곱셈 (완벽합니다!)
            mult_stage <= 64'd1 * dataa * datab;
            
            // [Cycle 2] 최적화: 곱셈기 대신 Shift-Add 사용
            // * 1311 / 2^19 ≈ 1/400 (오차 0.02%)
            // * 1311 = * (1024 + 256 + 32 - 1) = (x<<10) + (x<<8) + (x<<5) - x
            result <= ((mult_stage << 10) + (mult_stage << 8) + (mult_stage << 5) - mult_stage) >> 19;      
        end
    end

endmodule