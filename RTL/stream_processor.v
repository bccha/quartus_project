`timescale 1ns / 1ps
module stream_processor (
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-MM Slave (제어 인터페이스)
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire        avs_read,
    output wire [31:0] avs_readdata,
    output reg         avs_readdatavalid,
    input  wire [1:0]  avs_address,  // 2비트 주소 (최대 4개 레지스터)

    // Avalon-ST Sink (DMA Read로부터 데이터 입력)
    input  wire        asi_valid,
    input  wire [31:0] asi_data,
    output wire        asi_ready,

    // Avalon-ST Source (DMA Write로 데이터 출력)
    output wire        aso_valid,
    output wire [31:0] aso_data,
    input  wire        aso_ready
);

    // --------------------------------------------------------
    // CSR (Control Status Register) 제어 로직
    // --------------------------------------------------------
    
    // 하드웨어 버전 정보 (RTL 업데이트 시 수동으로 변경)
    localparam VERSION = 32'h0000_0110; // v1.10: 3단 파이프라인 + 바이패스 + 엔디안 수정
    
    reg [31:0] coeff_a;
    reg        bypass;
    reg [31:0] in_count;
    reg [31:0] out_count;
    reg [31:0] avs_readdata_reg;
    
    // 디버깅용 신호 활성 카운터
    reg [31:0] asi_valid_count;  // asi_valid가 High였던 횟수
    reg [31:0] aso_ready_count;  // aso_ready가 High였던 횟수

    assign avs_readdata = avs_readdata_reg;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            coeff_a   <= VERSION; 
            bypass    <= 1'b0;
            avs_readdata_reg     <= 32'd0;
            avs_readdatavalid    <= 1'b0;
            asi_valid_count      <= 32'd0;
            aso_ready_count      <= 32'd0;
        end else begin
            // Write Logic
            if (avs_write) begin
                case (avs_address)
                    2'b00: coeff_a <= avs_writedata;
                    2'b01: bypass  <= avs_writedata[0];
                endcase
            end
            
            // 읽기 로직 (1 사이클 지연으로 Avalon 규격 준수)
            avs_readdatavalid <= avs_read;
            if (avs_read) begin
                case (avs_address)
                    2'b00: avs_readdata_reg <= coeff_a;
                    2'b01: avs_readdata_reg <= {31'd0, bypass};
                    2'b10: avs_readdata_reg <= asi_valid_count;
                    2'b11: avs_readdata_reg <= last_asi_data;
                endcase
            end
            
            if (asi_valid) asi_valid_count <= asi_valid_count + 1;
            if (aso_ready) aso_ready_count <= aso_ready_count + 1;
        end
    end

    // --------------------------------------------------------
    // N단 파이프라인 구조 (N-Stage Pipeline)
    // --------------------------------------------------------
    parameter STAGES = 3;

    // 파이프라인 제어 신호
    reg [STAGES-1:0] pipe_valid;    // 유효 비트 (Valid bits)
    wire [STAGES:0]   pipe_ready;    // 준비 비트 (Ready bits - Backpressure)
    
    // 파이프라인 데이터 레지스터 (배열)
    reg [31:0] stage_data [0:STAGES-1]; 
    reg [63:0] intermediate_prod;       
    reg [31:0] last_asi_data;           

    // [백프레셔 전파]
    assign pipe_ready[STAGES] = aso_ready;
    genvar i;
    generate
        for (i = 0; i < STAGES; i = i + 1) begin : gen_ready
            assign pipe_ready[i] = !pipe_valid[i] || pipe_ready[i+1];
        end
    endgenerate

    assign asi_ready = pipe_ready[0];

    // 내부 연산 결과 저장을 위한 reg (always 내부 사용)
    reg [63:0] auto_res_calc;

    // 파이프라인 메인 로직
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pipe_valid <= {STAGES{1'b0}};
            intermediate_prod <= 64'd0;
            last_asi_data <= 32'd0;
            auto_res_calc <= 64'd0;
            in_count  <= 32'd0;
            out_count <= 32'd0;
        end else begin
            
            // --- [Stage 0]: 입력 및 엔디안 변환 ---
            if (pipe_ready[0]) begin
                pipe_valid[0] <= asi_valid;
                if (asi_valid) begin
                    stage_data[0] <= {asi_data[7:0], asi_data[15:8], asi_data[23:16], asi_data[31:24]};
                    last_asi_data <= {asi_data[7:0], asi_data[15:8], asi_data[23:16], asi_data[31:24]};
                    in_count <= in_count + 1;
                end
            end

            // --- [Stage 1]: 중간 곱셈 ---
            if (pipe_ready[1]) begin
                pipe_valid[1] <= pipe_valid[0];
                if (pipe_valid[0]) begin
                    if (bypass) begin
                        stage_data[1] <= stage_data[0];
                    end else begin
                        intermediate_prod <= (64'd1 * stage_data[0] * coeff_a);
                    end
                end
            end

            // --- [Stage 2]: 최종 역수 곱셈 및 엔디안 복원 ---
            if (pipe_ready[2]) begin
                pipe_valid[2] <= pipe_valid[1];
                if (pipe_valid[1]) begin
                    if (bypass) begin
                        stage_data[2] <= {stage_data[1][7:0], stage_data[1][15:8], stage_data[1][23:16], stage_data[1][31:24]};
                    end else begin
                        auto_res_calc = (intermediate_prod * 64'd5243) >> 21;
                        stage_data[2] <= {auto_res_calc[7:0], auto_res_calc[15:8], auto_res_calc[23:16], auto_res_calc[31:24]};
                    end
                    out_count <= out_count + 1;
                end
            end
        end
    end

    // 최종 출력 할당
    assign aso_valid = pipe_valid[STAGES-1];
    assign aso_data  = stage_data[STAGES-1];

endmodule
