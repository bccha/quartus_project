module simple_fifo #(
    parameter DATA_WIDTH = 32,
    parameter FIFO_DEPTH = 512
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   wr_en,
    input  wire [DATA_WIDTH-1:0]  wr_data,
    input  wire                   rd_en,
    output wire [DATA_WIDTH-1:0]  rd_data, // Changed to wire for FWFT
    output wire                   full,
    output wire                   empty,
    output reg  [$clog2(FIFO_DEPTH):0] used_w
);

    localparam ADDR_WIDTH = $clog2(FIFO_DEPTH);

    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;

    assign full  = (used_w == FIFO_DEPTH);
    assign empty = (used_w == 0);
    
    // FWFT: Data is always available at rd_ptr
    assign rd_data = mem[rd_ptr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            used_w <= 0;
        end else begin
            // Write
            if (wr_en && !full) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr <= (wr_ptr == FIFO_DEPTH-1) ? 0 : wr_ptr + 1;
            end

            // Read (Ack)
            if (rd_en && !empty) begin
                // Just increment pointer, data was already consumed
                rd_ptr <= (rd_ptr == FIFO_DEPTH-1) ? 0 : rd_ptr + 1;
            end

            // Usage Counter
            if (wr_en && !full && (!rd_en || empty)) begin
                used_w <= used_w + 1;
            end else if (rd_en && !empty && (!wr_en || full)) begin
                used_w <= used_w - 1;
            end
        end
    end

endmodule
