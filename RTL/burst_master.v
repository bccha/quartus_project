`timescale 1ns/1ps

/*
 * 모듈명: burst_master (Basic Version)
 * 
 * [개요]
 * Avalon Memory-Mapped (Avalon-MM) 인터페이스를 사용하여 Source 주소의 데이터를 
 * Destination 주소로 고속 복사하는 DMA(Direct Memory Access) 컨트롤러입니다.
 * 
 * [주요 특징]
 * 1. Burst Transfer:
 *    - 한 번의 주소 전송으로 여러 데이터(BURST_COUNT)를 연속으로 읽고 씁니다.
 *    - Avalon-MM 프로토콜의 Burst 기능을 활용하여 버스 효율을 극대화합니다.
 *    - 기본 Burst Count는 256 (Word 단위)입니다.
 * 
 * 2. FIFO 기반 Architecture:
 *    - Read Master와 Write Master 사이에 FIFO를 두어 도메인을 분리합니다.
 *    - Read Master는 FIFO가 꽉 차지 않는 한 계속 데이터를 읽어옵니다.
 *    - Write Master는 FIFO에 데이터가 쌓이면 데이터를 가져와 씁니다.
 *    - 이를 통해 Read/Write 속도 차이를 완충하고 병렬 동작을 가능하게 합니다.
 * 
 * [동작 흐름]
 * 1. 제어 신호(ctrl_start)가 입력되면 Source/Dest 주소와 길이를 래치합니다.
 * 2. Read Master FSM:
 *    - FIFO에 빈 공간이 충분한지 확인합니다 (Burst 단위).
 *    - 공간이 있으면 Avalon Bus에 Read 요청을 보냅니다.
 *    - 읽은 데이터는 valid 신호와 함께 FIFO에 저장됩니다.
 * 3. Write Master FSM:
 *    - FIFO에 데이터가 Burst 크기만큼 찼는지 확인합니다.
 *    - 데이터가 준비되면 Avalon Bus에 Write 요청을 보냅니다.
 * 4. 모든 데이터 전송이 완료되면 done 신호를 출력합니다.
 */

module burst_master #(
    parameter DATA_WIDTH = 32,      // 데이터 버스 폭 (32비트)
    parameter ADDR_WIDTH = 32,      // 주소 버스 폭 (32비트)
    parameter BURST_COUNT = 256,    // 한 번의 Burst 전송 당 전송할 워드 수 (256 words = 1KB)
    parameter FIFO_DEPTH = 512      // 내부 FIFO 깊이 (512 words = 2KB)
)(
    input  wire                   clk,      // 시스템 클럭
    input  wire                   reset_n,  // 비동기 리셋 (Active Low)

    // =========================================================================
    // Avalon-MM Slave Interface (CSR)
    // =========================================================================
    input  wire                   avs_write,
    input  wire                   avs_read,
    input  wire [2:0]             avs_address,    // 0~7 (Word 단위 주소)
    input  wire [31:0]            avs_writedata,
    output reg  [31:0]            avs_readdata,

    // =========================================================================
    // Avalon-MM Read Master Interface
    // =========================================================================
    output reg  [ADDR_WIDTH-1:0]  rm_address,       // 읽기 주소
    output reg                    rm_read,          // 읽기 요청 신호 (Read Enable)
    input  wire [DATA_WIDTH-1:0]  rm_readdata,      // 읽은 데이터 (From Slave)
    input  wire                   rm_readdatavalid, // 읽은 데이터 유효 신호 (From Slave)
    output reg  [8:0]             rm_burstcount,    // Burst 길이 요청 (항상 256)
    input  wire                   rm_waitrequest,   // Slave의 대기 요청 (1이면 명령 대기 필요)

    // =========================================================================
    // Avalon-MM Write Master Interface
    // =========================================================================
    output reg  [ADDR_WIDTH-1:0]  wm_address,       // 쓰기 주소
    output reg                    wm_write,         // 쓰기 요청 신호 (Write Enable)
    output wire [DATA_WIDTH-1:0]  wm_writedata,     // 쓸 데이터 (To Slave)
    output reg  [8:0]             wm_burstcount,    // Burst 길이 요청 (항상 256)
    input  wire                   wm_waitrequest    // Slave의 대기 요청 (1이면 데이터 유지 필요)
);

    // =========================================================================
    // 내부 신호 정의
    // =========================================================================

    // CSR Registers
    reg                   ctrl_start;
    reg                   ctrl_done;
    reg [ADDR_WIDTH-1:0]  ctrl_src_addr;
    reg [ADDR_WIDTH-1:0]  ctrl_dst_addr;
    reg [ADDR_WIDTH-1:0]  ctrl_len;

    // FIFO 연결 신호
    // Read Master -> FIFO -> Write Master 구조를 형성합니다.
    wire                   fifo_wr_en;   // FIFO 쓰기 요청 (Read Master에서 데이터 수신 시 High)
    wire [DATA_WIDTH-1:0]  fifo_wr_data; // FIFO 쓰기 데이터
    wire                   fifo_rd_en;   // FIFO 읽기 요청 (Write Master에서 데이터 송신 시 High)
    wire [DATA_WIDTH-1:0]  fifo_rd_data; // FIFO 읽기 데이터 (FWFT 방식)
    wire                   fifo_full;    // FIFO 가득 참
    wire                   fifo_empty;   // FIFO 비어 있음
    wire [$clog2(FIFO_DEPTH):0] fifo_used; // FIFO에 저장된 데이터 개수

    // 제어 레지스터: 현재 진행 상황을 저장합니다.
    reg [ADDR_WIDTH-1:0] current_src_addr;  // 현재 읽고 있는 소스 주소
    reg [ADDR_WIDTH-1:0] current_dst_addr;  // 현재 쓰고 있는 목적지 주소
    reg [ADDR_WIDTH-1:0] remaining_len;     // 남은 쓰기 길이 (바이트 단위)

    // =========================================================================
    // CSR Logic (Avalon-MM Slave)
    // =========================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ctrl_start    <= 0;
            ctrl_done_reg <= 0; // 내부 done 상태
            ctrl_src_addr <= 0;
            ctrl_dst_addr <= 0;
            ctrl_len      <= 0;
        end else begin
            // Pulse인 ctrl_start를 1클럭 후 Clear
            if (ctrl_start) ctrl_start <= 0;

            // FSM에서 작업 완료 시 Done 설정
            if (internal_done_pulse) begin
                ctrl_done_reg <= 1;
            end

            // Avalon-MM Write
            if (avs_write) begin
                case (avs_address)
                    3'd0: begin // Control
                        if (avs_writedata[0]) ctrl_start <= 1; // Start
                    end
                    3'd1: begin // Status
                        if (avs_writedata[0]) ctrl_done_reg <= 0; // Clear Done
                    end
                    3'd2: ctrl_src_addr <= avs_writedata; // Source Address
                    3'd3: ctrl_dst_addr <= avs_writedata; // Destination Address
                    3'd4: ctrl_len      <= avs_writedata; // Length
                endcase
            end
        end
    end

    // Avalon-MM Read
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
    
    // Internal Done Signal Hookup
    reg ctrl_done_reg;
    reg internal_done_pulse; // FSM에서 완료 시 Pulse 발생용
    
    // FSM 상태 정의
    localparam [1:0] IDLE = 2'b00,
                     READ = 2'b01,
                     WAIT_FIFO = 2'b10, 
                     DONE = 2'b11;
    
    // =========================================================================
    // Read Master FSM (데이터 읽기)
    // =========================================================================
    // Read Master는 FIFO 공간을 확인하고, 공간이 있으면 선제적으로 데이터를 읽어옵니다.
    
    reg [1:0] rm_state;
    reg [8:0] rm_word_cnt;               // 현재 Burst 내에서 전송된 워드 수 카운터
    reg [ADDR_WIDTH-1:0] pending_reads;  // In-flight Read Transaction 추적
                                         // (요청은 보냈으나 아직 데이터가 도착하지 않은 워드 수)
    reg [ADDR_WIDTH-1:0] read_remaining_len; // 읽어야 할 남은 총 길이 (바이트 단위)

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rm_state <= IDLE;
            rm_address <= 0;
            rm_read <= 0;
            rm_burstcount <= BURST_COUNT;
            current_src_addr <= 0;
            rm_word_cnt <= 0;
            pending_reads <= 0;
            read_remaining_len <= 0;
        end else begin
            // -----------------------------------------------------------------
            // Pending Read 추적 로직
            // -----------------------------------------------------------------
            // FIFO 오버플로우를 방지하기 위해 "이미 요청했지만 아직 도착하지 않은 데이터"를 계산합니다.
            // 1. 읽기 명령 수락 시 (READ state & !waitrequest): pending_reads += 256
            // 2. 데이터 수신 시 (readdatavalid): pending_reads -= 1
            // 3. 동시에 발생하면: pending_reads += 255
            
            if (rm_state == READ && !rm_waitrequest) begin
                 pending_reads <= pending_reads + BURST_COUNT - (rm_readdatavalid ? 1 : 0);
            end else if (rm_readdatavalid) begin
                 if (pending_reads > 0)
                    pending_reads <= pending_reads - 1;
            end

            // -----------------------------------------------------------------
            // Read State Machine
            // -----------------------------------------------------------------
            case (rm_state)
                IDLE: begin
                    // 시작 신호 대기
                    if (ctrl_start) begin
                        current_src_addr <= ctrl_src_addr;
                        read_remaining_len <= ctrl_len; // 전체 읽기 길이 설정
                        rm_state <= WAIT_FIFO;
                    end
                end

                WAIT_FIFO: begin
                    // FIFO 공간 확인
                    // 조건: (현재 FIFO 사용량 + 도착 예정 데이터 + 이번에 요청할 Burst 크기) <= FIFO 전체 깊이
                    // 이 조건이 충족되어야만 새로운 Burst 요청을 보낼 수 있습니다.
                    if (read_remaining_len > 0) begin
                         if ((fifo_used + pending_reads + BURST_COUNT) <= FIFO_DEPTH) begin
                            rm_address <= current_src_addr;  // 주소 설정
                            rm_read <= 1;                    // 읽기 요청 Assert
                            rm_burstcount <= BURST_COUNT;    // Burst 길이 설정
                            rm_word_cnt <= 0;
                            rm_state <= READ;                // READ 상태로 진입하여 명령 전송
                         end
                    end 
                    // read_remaining_len == 0이면 더 이상 읽을 데이터가 없으므로 대기 (Write Master가 완료할 때까지)
                end

                READ: begin
                   // Avalon-MM Spec: waitrequest가 0일 때 명령이 수락됨.
                   // Slave가 Busy 상태(waitrequest=1)이면 대기합니다.
                   if (!rm_waitrequest) begin
                       rm_read <= 0; // 명령 수락됨, 읽기 요청 신호 내림
                       
                       // 다음 Burst를 위해 주소 및 남은 길이 갱신
                       current_src_addr <= current_src_addr + (BURST_COUNT * 4); 
                       read_remaining_len <= read_remaining_len - (BURST_COUNT * 4);
                       
                       rm_state <= WAIT_FIFO; // 다시 FIFO 공간 확인 상태로 돌아감 (기본형 동작)
                   end
                end
            endcase
            
            // 전체 작업 완료 체크 (Write까지 모두 완료되었을 때)
             if (internal_done_pulse) begin
                rm_state <= IDLE;
                pending_reads <= 0; 
             end
        end
    end

    // FIFO 쓰기: Read Master가 유효한 데이터를 받으면(readdatavalid) FIFO에 씁니다.
    assign fifo_wr_en = rm_readdatavalid;
    assign fifo_wr_data = rm_readdata;


    // =========================================================================
    // Write Master FSM (데이터 쓰기)
    // =========================================================================
    // Write Master는 FIFO에 데이터가 충분히 쌓이기를 기다렸다가 Burst 단위로 씁니다.
    
    reg [1:0] wm_fsm;
    localparam W_IDLE = 2'b00, 
               W_WAIT_DATA = 2'b01, // FIFO 데이터 대기
               W_BURST = 2'b10;     // Burst 쓰기 수행
               
    reg [8:0] wm_word_cnt; // 현재 Burst 내 전송된 워드 수

    // FIFO Read Logic (FWFT 방식)
    assign fifo_rd_en = (wm_fsm == W_BURST) && (!wm_waitrequest) && (wm_word_cnt < BURST_COUNT);
    assign wm_writedata = fifo_rd_data; // FIFO 출력을 바로 Write Data로 연결
    
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wm_fsm <= W_IDLE;
            wm_write <= 0;
            wm_word_cnt <= 0;
            wm_address <= 0;
            current_dst_addr <= 0;
            remaining_len <= 0;
            internal_done_pulse <= 0; // Init
            wm_burstcount <= BURST_COUNT;
        end else begin
            internal_done_pulse <= 0; // Default Low
            
            case (wm_fsm)
                W_IDLE: begin
                    wm_write <= 0;
                    // 시작 신호 대기
                    if (ctrl_start) begin
                        current_dst_addr <= ctrl_dst_addr;
                        remaining_len <= ctrl_len; // 쓰기해야 할 전체 길이 설정
                        wm_fsm <= W_WAIT_DATA;
                    end
                end
                
                W_WAIT_DATA: begin
                    wm_write <= 0;
                    
                    if (remaining_len == 0) begin
                        // 모든 데이터를 다 썼으면 완료
                        internal_done_pulse <= 1; // Pulse 발생
                        wm_fsm <= W_IDLE;
                    end else if (fifo_used >= BURST_COUNT) begin
                        // FIFO에 한 번의 Burst(256개) 분량의 데이터가 모였는지 확인
                        // 데이터가 준비되면 Burst 쓰기 시작
                        wm_address <= current_dst_addr;
                        wm_fsm <= W_BURST;
                        wm_word_cnt <= 0;
                        wm_burstcount <= BURST_COUNT; // Burst 길이 설정
                        wm_write <= 1; // 쓰기 요청 Assert (Burst 시작)
                    end
                end
                
                W_BURST: begin
                    // Burst 쓰기 진행 중
                    // Avalon-MM Spec: waitrequest가 0이면 데이터가 Slave에 의해 받아들여짐
                    if (!wm_waitrequest) begin
                        // 현재 워드 전송 완료, 카운터 증가
                        if (wm_word_cnt == BURST_COUNT - 1) begin
                            // Burst 완료
                            wm_write <= 0; // 쓰기 요청 Deassert
                            
                            // 다음 Burst를 위해 주소 및 남은 길이 갱신
                            current_dst_addr <= current_dst_addr + (BURST_COUNT * 4);
                            remaining_len <= remaining_len - (BURST_COUNT * 4);
                            
                            wm_fsm <= W_WAIT_DATA; // 다시 데이터 대기 상태로
                        end else begin
                            wm_word_cnt <= wm_word_cnt + 1;
                            // wm_write는 Burst 동안 계속 High 유지
                        end
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // FIFO 인스턴스 (Simple FWFT FIFO)
    // =========================================================================
    // 데이터 버퍼링을 위한 FIFO입니다.
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
