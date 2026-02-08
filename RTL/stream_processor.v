module stream_processor (
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-MM Slave (제어 인터페이스)
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire        avs_read,
    output wire [31:0] avs_readdata,
    output wire        avs_readdatavalid,
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
    localparam VERSION = 32'h0000_0103; // v1.03: 1단 파이프라인 + 바이패스 + 엔디안 수정
    
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
            coeff_a   <= VERSION; // Initialize to version number for easy verification
            bypass    <= 1'b0;
            //in_count  <= 32'd0;
            //out_count <= 32'd0;
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
                    // Address 2,3 are read-only (debug counters)
                endcase
            end
            
            // 읽기 로직 (1 사이클 지연으로 Avalon 규격 준수)
            avs_readdatavalid <= avs_read;
            if (avs_read) begin
                case (avs_address)
                    2'b00: avs_readdata_reg <= coeff_a;
                    2'b01: avs_readdata_reg <= {31'd0, bypass};
                    2'b10: avs_readdata_reg <= asi_valid_count;  // 디버깅용
                    2'b11: avs_readdata_reg <= last_asi_data;    // 디버깅용: 마지막 입력 데이터 확인
                endcase
            end
            
            // DEBUG: Count signal activity
            if (asi_valid) asi_valid_count <= asi_valid_count + 1;
            if (aso_ready) aso_ready_count <= aso_ready_count + 1;

            // Debug Counters
            // These counters are now handled within the pipeline stages for more accurate tracking.
            // if (asi_valid && asi_ready) in_count  <= in_count + 1;
            // if (aso_valid && aso_ready) out_count <= out_count + 1;
        end
    end

    // --------------------------------------------------------
    // Simplified 1-Stage Pipeline (Input * Coeff)
    // --------------------------------------------------------

    // 파이프라인 1단계용 출력 레지스터
    reg [31:0] aso_data_reg;
    reg        aso_valid_reg; // 1비트 유효 플래그
    reg [31:0] last_asi_data; // 디버깅용 저장 레지스터
    
    // 중간 연산용 변수
    reg [31:0] in_swapped;
    reg [31:0] res_calc;

    
    // [핸드셰이크/백프레셔 로직]: 새로운 데이터를 받을 수 있는 상태(asi_ready) 결정
    // 하드웨어는 다음 두 경우에만 새로운 입력을 받을 수 있습니다:
    // 1. 현재 파이프라인(출력 레지스터)이 비어 있거나 (!aso_valid_reg)
    // 2. 파이프라인이 차 있어도, 다음 단계(Write Master 등)에서 데이터를 가져가고 있는 경우 (aso_ready)
    assign asi_ready = (!aso_valid_reg) || aso_ready;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            aso_valid_reg <= 1'b0;
            aso_data_reg  <= 32'd0;
            last_asi_data <= 32'd0;
        end else begin
            // -------------------------------------------------------------
            // [파이프라인 단계 1]: 단일 사이클 입력 & 연산 (Input & Calc)
            // -------------------------------------------------------------
            // 조건: 현재 준비됨(Ready) && 입력 데이터 유효함(Valid)
            if (asi_ready && asi_valid) begin
                aso_valid_reg <= 1'b1; // 출력 데이터 유효함 표시

                // 1. [엔디안 변환] (Big-Endian DMA -> Little-Endian Logic)
                // mSGDMA는 Big-Endian으로 데이터를 보내므로, 바이트 순서를 뒤집어야 합니다.
                // 예: 입력 0x90010000 -> 변환 후 0x00000190 (400)
                in_swapped = {asi_data[7:0], asi_data[15:8], asi_data[23:16], asi_data[31:24]};
                
                // 디버깅용: 변환된 입력 데이터 저장
                last_asi_data <= in_swapped; 

                // 2. [모드 선택 및 연산]
                if (bypass) begin
                    // [Bypass 모드]: 연산 없이 통과
                    // 입력된 데이터를 그대로 출력 (엔디안 변환은 유지해야 DMA가 올바르게 읽음)
                    aso_data_reg <= {in_swapped[7:0], in_swapped[15:8], in_swapped[23:16], in_swapped[31:24]}; 
                end else begin
                    // [연산 모드]: (입력 * Coeff) / 400
                    // 최적화: 나눗셈(/400)은 너무 느리므로 역수 곱셈으로 대체
                    // 1/400 ≈ 0.0025
                    // 0.0025 * 2^21 ≈ 5243 (고정 소수점 연산)
                    // 결과 = (입력 * Coeff * 5243) >> 21
                    
                    // A. 연산 수행 (단일 사이클 내 처리)
                    res_calc = ((in_swapped * coeff_a) * 32'd5243) >> 21;
                    
                    // B. [엔디안 복원] (Logic -> Big-Endian DMA)
                    // 결과를 다시 mSGDMA가 이해할 수 있는 순서로 뒤집어서 출력 레지스터에 저장
                    aso_data_reg <= {res_calc[7:0], res_calc[15:8], res_calc[23:16], res_calc[31:24]};
                end
                
                // 디버깅 카운터 증가
                in_count  <= in_count + 1;
                out_count <= out_count + 1;

            end else if (aso_ready && aso_valid_reg) begin
                // [데이터 전송 완료]
                // 다음 단(Sink)이 데이터를 가져갔으므로(Ready), 유효 비트를 끕니다.
                aso_valid_reg <= 1'b0;
            end
            // else: Stall (대기 상태 유지)
        end
    end

    // Downstream Output Assignment
    assign aso_valid = aso_valid_reg;
    assign aso_data  = aso_data_reg;

endmodule

