`timescale 1ns/1ps

/*
 * 모듈명: burst_master_3 (Calculation Pipeline Version)
 * 
 * [개요]
 * burst_master_2의 고성능 아키텍처(Pipelined Read, Continuous Write)를 기반으로
 * 데이터 처리(곱셈 연산) 파이프라인을 추가한 버전입니다.
 * 
 * [아키텍처: Two-FIFO Structure]
 * Read Master -> [Input FIFO] -> [Multiplier Stage] -> [Output FIFO] -> Write Master
 * 
 * 1. Read Master: 데이터를 읽어 Input FIFO에 채웁니다.
 * 2. Pipeline: Input FIFO에서 데이터를 꺼내 Coeff와 곱한 뒤 Output FIFO에 넣습니다.
 * 3. Write Master: Output FIFO에 데이터가 쌓이면 메모리에 씁니다.
 * 
 * [CSR Register Map]
 * 0x00: Control (Start)
 * 0x01: Status (Done)
 * 0x02: Src Addr
 * 0x03: Dst Addr
 * 0x04: Length
 * 0x05: Coefficient (New!) - 곱셈 계수
 */

module burst_master_3 #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32,
    parameter BURST_COUNT = 256,
    parameter FIFO_DEPTH = 512
)(
    input  wire                   clk,
    input  wire                   reset_n,

    // =========================================================================
    // Control Interface (Avalon-MM CSR Slave)
    // =========================================================================
    input  wire                   avs_write,
    input  wire                   avs_read,
    input  wire [2:0]             avs_address,
    input  wire [31:0]            avs_writedata,
    output reg  [31:0]            avs_readdata,

    // =========================================================================
    // Avalon-MM Read Master Interface
    // =========================================================================
    output reg  [ADDR_WIDTH-1:0]  rm_address,
    output reg                    rm_read,
    input  wire [DATA_WIDTH-1:0]  rm_readdata,
    input  wire                   rm_readdatavalid,
    output reg  [8:0]             rm_burstcount,
    input  wire                   rm_waitrequest,

    // =========================================================================
    // Avalon-MM Write Master Interface
    // =========================================================================
    output reg  [ADDR_WIDTH-1:0]  wm_address,
    output reg                    wm_write,
    output wire [DATA_WIDTH-1:0]  wm_writedata,
    output reg  [8:0]             wm_burstcount,
    input  wire                   wm_waitrequest
);

    // =========================================================================
    // Internal Signals & Registers
    // =========================================================================

    // Input FIFO Signals (Read Master -> Pipeline)
    wire                   fifo_in_wr_en;
    wire [DATA_WIDTH-1:0]  fifo_in_wr_data;
    reg                    fifo_in_rd_en;      // Pipeline에서 제어
    wire [DATA_WIDTH-1:0]  fifo_in_rd_data;
    wire                   fifo_in_full;
    wire                   fifo_in_empty;
    wire [$clog2(FIFO_DEPTH):0] fifo_in_used;

    // Output FIFO Signals (Pipeline -> Write Master)
    reg                    fifo_out_wr_en;     // Pipeline에서 제어
    reg  [DATA_WIDTH-1:0]  fifo_out_wr_data;   // Pipeline에서 제어
    wire                   fifo_out_rd_en;     // Write Master에서 제어
    wire [DATA_WIDTH-1:0]  fifo_out_rd_data;
    wire                   fifo_out_full;
    wire                   fifo_out_empty;
    wire [$clog2(FIFO_DEPTH):0] fifo_out_used;

    // CSR Registers
    reg                   ctrl_start;
    reg                   ctrl_done_reg;
    reg [ADDR_WIDTH-1:0]  ctrl_src_addr;
    reg [ADDR_WIDTH-1:0]  ctrl_dst_addr;
    reg [ADDR_WIDTH-1:0]  ctrl_len;
    reg [31:0]            ctrl_coeff; // Multiplier Coefficient
    reg                   internal_done_pulse;

    // FSM State Registers
    reg [ADDR_WIDTH-1:0] current_src_addr;
    reg [ADDR_WIDTH-1:0] current_dst_addr;
    reg [ADDR_WIDTH-1:0] remaining_len; // Write Master용

    reg [ADDR_WIDTH-1:0] read_remaining_len; 
    reg [ADDR_WIDTH-1:0] pending_reads; 
    
    // Read Pipelining Temps
    reg [ADDR_WIDTH-1:0] rm_next_addr;
    reg [ADDR_WIDTH-1:0] rm_next_rem;
    
    // Write Pipelining Temps
    reg [ADDR_WIDTH-1:0] wm_next_dst;
    reg [ADDR_WIDTH-1:0] wm_next_rem; 

    // States
    localparam [1:0] IDLE = 2'b00,
                     READ = 2'b01,
                     WAIT_FIFO = 2'b10;

    localparam [1:0] W_IDLE = 2'b00, 
                     W_WAIT_DATA = 2'b01, 
                     W_BURST = 2'b10;

    // =========================================================================
    // CSR Logic
    // =========================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ctrl_start    <= 0;
            ctrl_done_reg <= 0;
            ctrl_src_addr <= 0;
            ctrl_dst_addr <= 0;
            ctrl_len      <= 0;
            ctrl_coeff    <= 32'd1; // Default to 1 (Bypass)
        end else begin
            if (ctrl_start) ctrl_start <= 0; 
            if (internal_done_pulse) ctrl_done_reg <= 1;

            if (avs_write) begin
                case (avs_address)
                    3'd0: if (avs_writedata[0]) ctrl_start <= 1;
                    3'd1: if (avs_writedata[0]) ctrl_done_reg <= 0;
                    3'd2: ctrl_src_addr <= avs_writedata;
                    3'd3: ctrl_dst_addr <= avs_writedata;
                    3'd4: ctrl_len      <= avs_writedata;
                    3'd5: ctrl_coeff    <= avs_writedata; // New Register
                endcase
            end
        end
    end

    always @(*) begin
        case (avs_address)
            3'd0: avs_readdata = {31'b0, ctrl_start};
            3'd1: avs_readdata = {31'b0, ctrl_done_reg};
            3'd2: avs_readdata = ctrl_src_addr;
            3'd3: avs_readdata = ctrl_dst_addr;
            3'd4: avs_readdata = ctrl_len;
            3'd5: avs_readdata = ctrl_coeff;
            default: avs_readdata = 32'b0;
        endcase
    end

    // =========================================================================
    // Read Master FSM (Fills Input FIFO)
    // =========================================================================
    reg [1:0] rm_state;
    
    // Input FIFO Write Connection
    assign fifo_in_wr_en = rm_readdatavalid;
    assign fifo_in_wr_data = rm_readdata;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rm_state <= IDLE;
            rm_address <= 0;
            rm_read <= 0;
            rm_burstcount <= BURST_COUNT;
            current_src_addr <= 0;
            pending_reads <= 0;
            read_remaining_len <= 0;
        end else begin
            // Pending Read Tracking
            if (rm_state == READ && !rm_waitrequest) begin
                 pending_reads <= pending_reads + BURST_COUNT - (rm_readdatavalid ? 1 : 0);
            end else if (rm_readdatavalid) begin
                 if (pending_reads > 0)
                    pending_reads <= pending_reads - 1;
            end

            case (rm_state)
                IDLE: begin
                    if (ctrl_start) begin
                        current_src_addr <= ctrl_src_addr;
                        read_remaining_len <= ctrl_len;
                        rm_state <= WAIT_FIFO;
                    end
                end

                WAIT_FIFO: begin
                    if (read_remaining_len > 0) begin
                         // Check Input FIFO Space
                         if ((fifo_in_used + pending_reads + BURST_COUNT) <= FIFO_DEPTH) begin
                            rm_address <= current_src_addr;
                            rm_read <= 1;
                            rm_burstcount <= BURST_COUNT;
                            rm_state <= READ;
                         end
                    end 
                    // Note: Read FSM doesn't drive DONE. Write FSM does.
                    if (internal_done_pulse) rm_state <= IDLE;
                end

                READ: begin
                   if (!rm_waitrequest) begin
                       rm_next_addr = current_src_addr + (BURST_COUNT * 4);
                       rm_next_rem = read_remaining_len - (BURST_COUNT * 4);
                       
                       current_src_addr <= rm_next_addr;
                       read_remaining_len <= rm_next_rem;
                       
                       if (rm_next_rem > 0 && 
                          ((fifo_in_used + pending_reads + BURST_COUNT + BURST_COUNT) <= FIFO_DEPTH)) begin
                           rm_address <= rm_next_addr;
                           rm_read <= 1; 
                           rm_state <= READ;
                       end else begin
                           rm_read <= 0;
                           rm_state <= WAIT_FIFO;
                       end
                   end
                end
            endcase
            
             if (internal_done_pulse) begin
                rm_state <= IDLE;
                pending_reads <= 0; 
             end
        end
    end

    // =========================================================================
    // Calculation Pipeline (Input FIFO -> Multiplier -> Output FIFO)
    // =========================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fifo_in_rd_en <= 0;
            fifo_out_wr_en <= 0;
            fifo_out_wr_data <= 0;
        end else begin
            // Default
            fifo_in_rd_en <= 0;
            fifo_out_wr_en <= 0;
            
            // Pipeline Logic:
            // Input FIFO에 데이터가 있고(Empty 아님) && Output FIFO가 꽉 차지 않았으면
            // 데이터를 하나 꺼내서 곱셈 후 Output FIFO에 넣습니다.
            // (Simple 1-cycle latency pipeline)
            
            // FWFT 가정: !empty 이면 rd_data는 유효함
            if (!fifo_in_empty && !fifo_out_full) begin
                fifo_in_rd_en <= 1; // Ack input
                
                // Process and Write
                fifo_out_wr_en <= 1;
                fifo_out_wr_data <= fifo_in_rd_data * ctrl_coeff; 
            end
        end
    end

    // =========================================================================
    // Write Master FSM (Drains Output FIFO)
    // =========================================================================
    reg [1:0] wm_fsm;
    reg [8:0] wm_word_cnt;

    // Output FIFO Read Connection
    assign fifo_out_rd_en = (wm_fsm == W_BURST) && (!wm_waitrequest) && (wm_word_cnt < BURST_COUNT);
    assign wm_writedata = fifo_out_rd_data;
    
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wm_fsm <= W_IDLE;
            wm_write <= 0;
            wm_word_cnt <= 0;
            wm_address <= 0;
            current_dst_addr <= 0;
            remaining_len <= 0;
            internal_done_pulse <= 0;
            wm_burstcount <= BURST_COUNT;
        end else begin
            internal_done_pulse <= 0;
            
            case (wm_fsm)
                W_IDLE: begin
                    wm_write <= 0;
                    if (ctrl_start) begin
                        current_dst_addr <= ctrl_dst_addr;
                        remaining_len <= ctrl_len;
                        wm_fsm <= W_WAIT_DATA;
                    end
                end
                
                W_WAIT_DATA: begin
                    wm_write <= 0;
                    if (remaining_len == 0) begin
                        internal_done_pulse <= 1; // Done!
                        wm_fsm <= W_IDLE;
                    end else if (fifo_out_used >= BURST_COUNT) begin
                        // Check Output FIFO
                        wm_address <= current_dst_addr;
                        wm_fsm <= W_BURST;
                        wm_word_cnt <= 0;
                        wm_write <= 1; 
                        wm_burstcount <= BURST_COUNT;
                    end
                end
                
                W_BURST: begin
                    if (!wm_waitrequest) begin
                        if (wm_word_cnt == BURST_COUNT - 1) begin
                            
                            wm_next_dst = current_dst_addr + (BURST_COUNT * 4);
                            wm_next_rem = remaining_len - (BURST_COUNT * 4);
                            
                            current_dst_addr <= wm_next_dst;
                            remaining_len <= wm_next_rem;

                            // Continuous Write Check (Output FIFO)
                            if (wm_next_rem > 0 && fifo_out_used >= (BURST_COUNT + 1)) begin
                                wm_address <= wm_next_dst;
                                wm_word_cnt <= 0;
                                wm_write <= 1; 
                                wm_fsm <= W_BURST; 
                            end else begin
                                wm_write <= 0;
                                wm_fsm <= W_WAIT_DATA;
                            end
                        end else begin
                            wm_word_cnt <= wm_word_cnt + 1;
                        end
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // FIFO Instances
    // =========================================================================
    
    // Input FIFO
    simple_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_fifo_in (
        .clk     (clk),
        .rst_n   (reset_n),
        .wr_en   (fifo_in_wr_en),
        .wr_data (fifo_in_wr_data),
        .rd_en   (fifo_in_rd_en),
        .rd_data (fifo_in_rd_data),
        .full    (fifo_in_full),
        .empty   (fifo_in_empty),
        .used_w  (fifo_in_used)
    );

    // Output FIFO
    simple_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_fifo_out (
        .clk     (clk),
        .rst_n   (reset_n),
        .wr_en   (fifo_out_wr_en),
        .wr_data (fifo_out_wr_data),
        .rd_en   (fifo_out_rd_en),
        .rd_data (fifo_out_rd_data),
        .full    (fifo_out_full),
        .empty   (fifo_out_empty),
        .used_w  (fifo_out_used)
    );

endmodule
