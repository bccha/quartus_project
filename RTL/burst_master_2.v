`timescale 1ns/1ps

/*
 * 모듈명: burst_master_2 (Low Latency / High Throughput Version)
 * 
 * [개요]
 * burst_master의 성능 향상 버전으로, 대량의 데이터를 더 빠르게 처리하기 위해
 * Pipelined Read와 Continuous Write 기능을 구현했습니다.
 * 
 * [주요 개선 사항]
 * 1. Pipelined Read (Back-to-Back Read):
 *    - 기존: Read 명령 -> 완료 -> 대기 -> FIFO 체크 -> 다음 Read 명령
 *    - 개선: Read 명령 수락(Ack) 즉시 -> FIFO 체크 -> 다음 Read 명령 발행
 *    - 효과: Read Latency를 숨기고 Bus 사용률을 100%에 가깝게 유지합니다.
 * 
 * 2. Continuous Write (Back-to-Back Write):
 *    - 기존: Burst 쓰기 완료 -> 대기 상태(Wait Data) -> FIFO 체크 -> 다음 Burst 시작
 *    - 개선: Burst 쓰기 완료 시점에 FIFO에 다음 데이터가 충분하면 Idle 없이 연속으로 다음 Burst 시작
 *    - 효과: Write 사이의 불필요한 공백(Idle Cycle)을 제거합니다.
 * 
 * [FSM 구조 변화]
 * - Read FSM: READ 상태에서 명령이 수락되면, WAIT_FIFO로 가지 않고 
 *             조건 충족 시 즉시 READ 상태를 유지하며 다음 주소를 출력합니다.
 * - Write FSM: BURST 상태 종료 시점에 다음 Burst 조건(데이터 충분)을 체크하여
 *              W_WAIT_DATA로 가지 않고 W_BURST 상태를 유지합니다.
 */

module burst_master_2 #(
    parameter DATA_WIDTH = 32,      // 데이터 버스 폭
    parameter ADDR_WIDTH = 32,      // 주소 버스 폭
    parameter BURST_COUNT = 256,    // Burst 길이
    parameter FIFO_DEPTH = 512      // FIFO 깊이
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

    // FIFO Signals
    wire                   fifo_wr_en;
    wire [DATA_WIDTH-1:0]  fifo_wr_data;
    wire                   fifo_rd_en;
    wire [DATA_WIDTH-1:0]  fifo_rd_data;
    wire                   fifo_full;
    wire                   fifo_empty;
    wire [$clog2(FIFO_DEPTH):0] fifo_used;

    // Internal Registers for Control
    reg                   ctrl_start;
    reg                   ctrl_done_reg;
    reg [ADDR_WIDTH-1:0]  ctrl_src_addr;
    reg [ADDR_WIDTH-1:0]  ctrl_dst_addr;
    reg [ADDR_WIDTH-1:0]  ctrl_len;
    reg                   internal_done_pulse;

    // FSM Internal Registers
    reg [ADDR_WIDTH-1:0] current_src_addr;
    reg [ADDR_WIDTH-1:0] current_dst_addr;
    reg [ADDR_WIDTH-1:0] remaining_len; // Write Master용 잔여 길이

    // =========================================================================
    // CSR Logic (Avalon-MM Slave)
    // =========================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ctrl_start    <= 0;
            ctrl_done_reg <= 0;
            ctrl_src_addr <= 0;
            ctrl_dst_addr <= 0;
            ctrl_len      <= 0;
        end else begin
            if (ctrl_start) ctrl_start <= 0; // Auto-clear

            if (internal_done_pulse) ctrl_done_reg <= 1;

            if (avs_write) begin
                case (avs_address)
                    3'd0: if (avs_writedata[0]) ctrl_start <= 1;
                    3'd1: if (avs_writedata[0]) ctrl_done_reg <= 0; // Clear Done
                    3'd2: ctrl_src_addr <= avs_writedata;
                    3'd3: ctrl_dst_addr <= avs_writedata;
                    3'd4: ctrl_len      <= avs_writedata;
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
            default: avs_readdata = 32'b0;
        endcase
    end

    // Read Master용 상태 관리 변수
    reg [ADDR_WIDTH-1:0] read_remaining_len; 
    reg [ADDR_WIDTH-1:0] pending_reads; // In-flight Read 카운트
    
    // 계산을 위한 임시 레지스터 (Pipelining 로직용)
    reg [ADDR_WIDTH-1:0] rm_next_addr;
    reg [ADDR_WIDTH-1:0] rm_next_rem;
    reg [ADDR_WIDTH-1:0] wm_next_dst;
    reg [ADDR_WIDTH-1:0] wm_next_rem; 

    localparam [1:0] IDLE = 2'b00,
                     READ = 2'b01,
                     WAIT_FIFO = 2'b10;

    // =========================================================================
    // Read Master FSM (Pipelined)
    // =========================================================================
    reg [1:0] rm_state;
    
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
            // -----------------------------------------------------------------
            // Pending Read Tracking
            // -----------------------------------------------------------------
            // 파이프라인 읽기를 위해서는 In-flight Transaction 관리가 필수적입니다.
            if (rm_state == READ && !rm_waitrequest) begin
                 // 명령이 수락되면 pending 카운트 증가
                 pending_reads <= pending_reads + BURST_COUNT - (rm_readdatavalid ? 1 : 0);
            end else if (rm_readdatavalid) begin
                 // 데이터가 들어오면 pending 카운트 감소
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
                    // 기본 진입점: FIFO 공간을 확인하고 첫 Burst를 시작합니다.
                    if (read_remaining_len > 0) begin
                         if ((fifo_used + pending_reads + BURST_COUNT) <= FIFO_DEPTH) begin
                            rm_address <= current_src_addr;
                            rm_read <= 1;
                            rm_burstcount <= BURST_COUNT;
                            rm_state <= READ;
                         end
                    end 
                    // 모든 읽기 완료 시 IDLE로 복귀 (Write 완료는 별도 체크)
                    if (internal_done_pulse) rm_state <= IDLE; // Pulse 감지 시 복귀
                end

                READ: begin
                   if (!rm_waitrequest) begin
                       /* 
                        * [핵심 로직: Pipelined Read]
                        * 현재 명령이 Slave에 의해 수락된 이 시점(Cycle)에,
                        * 즉시 다음 명령을 보낼 수 있는지 판단하여 State transition 없이 연속 전송합니다.
                        */
                       
                       // 1. 다음 Burst 정보 미리 계산
                       rm_next_addr = current_src_addr + (BURST_COUNT * 4);
                       rm_next_rem = read_remaining_len - (BURST_COUNT * 4);
                       
                       // 2. 현재 상태 업데이트
                       current_src_addr <= rm_next_addr;
                       read_remaining_len <= rm_next_rem;
                       
                       // 3. 다음 Burst 가능 여부 체크
                       // 조건: (현재 사용량 + 도착 예정 + 현재 요청한 것 + 다음 요청할 것) <= FIFO 깊이
                       // 여기서 BURST_COUNT가 두 번 더해지는 이유는:
                       // - 하나는 방금 수락된 Burst (아직 pending_reads에 반영 전일 수 있음/혹은 로직상 안전마진)
                       // - 하나는 앞으로 요청할 Burst
                       if (rm_next_rem > 0 && 
                          ((fifo_used + pending_reads + BURST_COUNT + BURST_COUNT) <= FIFO_DEPTH)) begin
                           
                           // [Case 1: 연속 전송 가능]
                           // rm_read를 0으로 내리지 않고 그대로 1 유지
                           // 주소만 다음 주소로 즉시 변경
                           rm_address <= rm_next_addr;
                           rm_read <= 1; 
                           rm_state <= READ; // 상태 유지 -> Back-to-Back Request 발생
                       end else begin
                           // [Case 2: 연속 전송 불가능 (FIFO 공간 부족 등)]
                           // rm_read Deassert 후 대기 상태로 전환
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

    // FIFO Write 연결
    assign fifo_wr_en = rm_readdatavalid;
    assign fifo_wr_data = rm_readdata;


    // =========================================================================
    // Write Master FSM (Continuous)
    // =========================================================================
    reg [1:0] wm_fsm;
    reg [8:0] wm_word_cnt;
    localparam W_IDLE = 2'b00, 
               W_WAIT_DATA = 2'b01, 
               W_BURST = 2'b10;

    // FWFT FIFO Read Logic
    assign fifo_rd_en = (wm_fsm == W_BURST) && (!wm_waitrequest) && (wm_word_cnt < BURST_COUNT);
    assign wm_writedata = fifo_rd_data;
    
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
            internal_done_pulse <= 0; // Default
            
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
                        internal_done_pulse <= 1; // Pulse
                        wm_fsm <= W_IDLE;
                    end else if (fifo_used >= BURST_COUNT) begin
                        // 데이터 준비됨 -> Burst 시작
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
                            // Burst 완료 시점
                            
                            /* 
                             * [핵심 로직: Continuous Write]
                             * 현재 Burst가 끝나는 즉시 다음 Burst 데이터가 있는지 확인합니다.
                             */

                            // 1. 다음 주소/길이 계산
                            wm_next_dst = current_dst_addr + (BURST_COUNT * 4);
                            wm_next_rem = remaining_len - (BURST_COUNT * 4);
                            
                            current_dst_addr <= wm_next_dst;
                            remaining_len <= wm_next_rem;

                            // 2. 연속 쓰기 조건 체크
                            // FIFO에 다음 Burst 분량(256) 이상의 데이터가 이미 있는지 확인
                            // (주의: 현재 클럭에서 마지막 데이터를 쓰고 있으므로, 안전하게 256+1 이상 체크)
                            if (wm_next_rem > 0 && fifo_used >= (BURST_COUNT + 1)) begin
                                // [Case 1: 연속 쓰기 가능]
                                // wm_write를 0으로 내리지 않고 1 유지
                                wm_address <= wm_next_dst;
                                wm_word_cnt <= 0;
                                wm_write <= 1; 
                                wm_fsm <= W_BURST; // 상태 유지
                            end else begin
                                // [Case 2: 데이터 부족]
                                // 일단 멈추고 대기 상태로
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

    // FIFO Instance
    simple_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_fifo (
        .clk     (clk),
        .rst_n   (reset_n),
        .wr_en   (fifo_wr_en),
        .wr_data (fifo_wr_data),
        .rd_en   (fifo_rd_en),
        .rd_data (fifo_rd_data),
        .full    (fifo_full),
        .empty   (fifo_empty),
        .used_w  (fifo_used)
    );

endmodule
