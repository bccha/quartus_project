/*
 * N-Stage Pipeline Template (N단 파이프라인 템플릿)
 * 
 * - 구조: Avalon-ST 규격의 Valid/Ready 핸드셰이크를 지원하는 정석적인 파이프라인
 * - 특징: 
 *   1. STAGES 파라미터로 단수 조절 가능
 *   2. 백프레셔(Backpressure) 지원: 뒤가 막히면 앞도 차례로 멈춤
 *   3. Throughput: 1 sample / cycle 유지
 */

module pipe_template #(
    parameter STAGES     = 3,   // 파이프라인 단계 수
    parameter DATA_WIDTH = 32   // 데이터 비트 폭
)(
    input  wire                  clk,
    input  wire                  reset_n,

    // 입력 인터페이스 (Sink)
    input  wire                  asi_valid,
    input  wire [DATA_WIDTH-1:0] asi_data,
    output wire                  asi_ready,

    // 출력 인터페이스 (Source)
    output wire                  aso_valid,
    output wire [DATA_WIDTH-1:0] aso_data,
    input  wire                  aso_ready
);

    // --------------------------------------------------------
    // 1. 제어 신호 및 데이터 레지스터 선언
    // --------------------------------------------------------
    reg [STAGES-1:0] pipe_valid;                      // Valid 파이프라인 (앞->뒤)
    wire [STAGES:0]   pipe_ready;                      // Ready 파이프라인 (뒤->앞)
    reg [DATA_WIDTH-1:0] d_pipe [0:STAGES-1];        // 데이터 파이프라인 레지스터

    // --------------------------------------------------------
    // 2. 백프레셔(Backpressure) 로직: Ready 신호의 역전파
    // --------------------------------------------------------
    assign pipe_ready[STAGES] = aso_ready; // 최종 출력단의 준비 상태

    genvar i;
    generate
        for (i = 0; i < STAGES; i = i + 1) begin : gen_handshake
            // 현재 단계가 데이터를 받을 수 있는 조건 (Ready):
            // "내가 현재 비어있거나(!pipe_valid[i])" OR "다음 단계가 내껄 가져갈 수 있거나(pipe_ready[i+1])"
            assign pipe_ready[i] = !pipe_valid[i] || pipe_ready[i+1];
        end
    endgenerate

    assign asi_ready = pipe_ready[0]; // 최종 입력단 준비 신호

    // --------------------------------------------------------
    // 3. 파이프라인 데이터 흐름
    // --------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pipe_valid <= {STAGES{1'b0}};
        end else begin
            
            // --- [Stage 0]: 첫 번째 단계 ---
            if (pipe_ready[0]) begin
                pipe_valid[0] <= asi_valid;
                if (asi_valid) begin
                    // TODO: 첫 번째 단계의 연산/로직을 여기에 작성
                    d_pipe[0] <= asi_data; 
                end
            end

            // --- [Stage 1 ~ N-1]: 중간 및 마지막 단계 ---
            // 루프를 사용하여 가변적인 STAGES에 대응
            // (실제 프로젝트에서는 각 단계마다 로직이 다르므로 명시적으로 기술하는 경우가 많음)
            /*
            integer j;
            for (j = 1; j < STAGES; j = j + 1) begin
                if (pipe_ready[j]) begin
                    pipe_valid[j] <= pipe_valid[j-1];
                    if (pipe_valid[j-1]) begin
                        // TODO: j번째 단계의 연산/로직을 여기에 작성
                        d_pipe[j] <= d_pipe[j-1] + 1; 
                    end
                end
            end
            */

            // 예시: 명시적 3단 구성 시
            if (STAGES >= 2 && pipe_ready[1]) begin
                pipe_valid[1] <= pipe_valid[0];
                if (pipe_valid[0]) d_pipe[1] <= d_pipe[0]; // Stage 1 로직
            end

            if (STAGES >= 3 && pipe_ready[2]) begin
                pipe_valid[2] <= pipe_valid[1];
                if (pipe_valid[1]) d_pipe[2] <= d_pipe[1]; // Stage 2 로직
            end

        end
    end

    // --------------------------------------------------------
    // 4. 최종 출력 할당
    // --------------------------------------------------------
    assign aso_valid = pipe_valid[STAGES-1];
    assign aso_data  = d_pipe[STAGES-1];

endmodule
