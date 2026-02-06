module stream_processor (
    input  wire        clk,
    input  wire        reset,

    // Avalon-MM Slave (Control Interface)
    // Address 0: Coefficient A (Default 1)
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire [0:0]  avs_address, // Single register (1-bit address space effectively, but usually word aligned)

    // Avalon-ST Sink (Input from DMA Read)
    input  wire        asi_valid,
    input  wire [31:0] asi_data,
    output wire        asi_ready,

    // Avalon-ST Source (Output to DMA Write)
    output wire        aso_valid,
    output wire [31:0] aso_data,
    input  wire        aso_ready
);

    // --------------------------------------------------------
    // CSR (Control Status Register) Logic
    // --------------------------------------------------------
    reg [31:0] coeff_a;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            coeff_a <= 32'd1; // Default multiplier = 1
        end else if (avs_write) begin
            // Address 0 check is implied if address width is 1 or just ignored if single register
            coeff_a <= avs_writedata;
        end
    end

    // --------------------------------------------------------
    // Generalized Pipeline Logic
    // --------------------------------------------------------
    // Define Stages:
    // Stage 0: Input Capture & Multiply (Input * A)
    // Stage 1: Division (Shift-Add)
    localparam NUM_STAGES = 2;

    reg  [63:0] stage_data  [0:NUM_STAGES-1]; // Data for each stage
    reg         stage_valid [0:NUM_STAGES-1]; // Valid for each stage
    wire        stage_enable[0:NUM_STAGES-1]; // Enable for each stage

    // Recursive Enable Logic (Backpressure)
    // enable[i] = (!valid[i]) || enable[i+1]
    // The last stage's "next enable" is the output ready signal (aso_ready)
    
    genvar i;
    generate
        for (i = 0; i < NUM_STAGES; i = i + 1) begin : pipe_ctrl
            if (i == NUM_STAGES - 1) begin
                // Last Stage: Next enable is Output Ready
                assign stage_enable[i] = (!stage_valid[i]) || aso_ready;
            end else begin
                // Typical Stage: Next enable is the next stage's enable signal
                // Note: enable[i+1] effectively means "next stage is ready to accept"
                // Actually, the formula is: enable[i] = (!valid[i]) || ( (!valid[i+1]) || enable[i+1_next] )
                // Which simplifies to: enable[i] = (!valid[i]) || stage_enable[i+1];
                assign stage_enable[i] = (!stage_valid[i]) || stage_enable[i+1];
            end
        end
    endgenerate

    // Datapath & Valid Logic
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            stage_valid[0] <= 1'b0;
            stage_valid[1] <= 1'b0;
            stage_data[0]  <= 64'd0;
            stage_data[1]  <= 64'd0;
        end else begin
            // Stage 0: Input -> Multiply
            if (stage_enable[0]) begin
                stage_valid[0] <= asi_valid;
                if (asi_valid) begin
                    stage_data[0] <= (asi_data * coeff_a); // 32x32=64 mult
                end
            end

            // Stage 1: Multiply -> Divide
            if (stage_enable[1]) begin
                stage_valid[1] <= stage_valid[0];
                if (stage_valid[0]) begin
                     // shift-add from stage 0 result
                     stage_data[1] <= ((stage_data[0] << 10) + (stage_data[0] << 8) + (stage_data[0] << 5) - stage_data[0]) >> 19;
                end
            end
        end
    end

    // Interface Assignments
    assign asi_ready = stage_enable[0];
    assign aso_valid = stage_valid[NUM_STAGES-1];
    assign aso_data  = stage_data[NUM_STAGES-1][31:0];

    /*
    // --------------------------------------------------------
    // REFERENCE: 2-Stage Manual Implementation
    // --------------------------------------------------------
    // This is how the logic looks without "generate" loop.
    // Useful for understanding the "valid-ready" handshake pattern.
    
    // Stage 1 Registers
    reg [63:0] s1_product; 
    reg        s1_valid;

    // Stage 2 Registers
    reg [31:0] s2_result;
    reg        s2_valid;

    // Handshake Logic
    // enable[i] = (Empty) || (Next Stage Ready)
    wire s1_enable = (!s1_valid) || ( (!s2_valid) || aso_ready ); 
    wire s2_enable = (!s2_valid) || aso_ready;

    // Input Ready
    assign asi_ready = s1_enable;

    // Stage 1: Capture Input -> Multiply
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            s1_valid   <= 1'b0;
            s1_product <= 64'd0;
        end else if (s1_enable) begin
            s1_valid   <= asi_valid;
            if (asi_valid) begin
                s1_product <= (asi_data * coeff_a);
            end
        end
    end

    // Stage 2: Shift-Add Division (/400)
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            s2_valid  <= 1'b0;
            s2_result <= 32'd0;
        end else if (s2_enable) begin
            s2_valid <= s1_valid;
            if (s1_valid) begin
                s2_result <= ((s1_product << 10) + (s1_product << 8) + (s1_product << 5) - s1_product) >> 19;
            end
        end
    end

    assign aso_valid = s2_valid;
    assign aso_data  = s2_result;
    */

endmodule
