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
    // Pipeline Logic
    // Stage 1: Multiplication (Input * A)
    // Stage 2: Division (Shift-Add Approximation for /400)
    // --------------------------------------------------------

    // Backpressure control:
    // We can accept input if output is ready, OR if we have bubble space.
    // To simplify simple pipelining, we often stall input if output stalls.
    // However, with multi-stage, we need careful valid/ready handling.
    // Here, we use a simple "stall all" approach: if output not ready, stall everything.

    wire pipeline_ready = aso_ready; // Simple forward pressure
    
    // Assign Input Ready
    // We are ready for input if the pipeline is moving (output is ready or pipeline is empty - simplifying to output ready for safety)
    // A more robust pipeline would check internal bubble states, but for mSGDMA, robust ready handling is preferred.
    // Let's implement a register-to-register pipeline with valid signals.

    reg [31:0] s1_data;   // Stage 1 Result (Input * A) - technically 64-bit needed? 
    // Wait, Input is 32-bit, A is 32-bit. Result is 64-bit.
    reg [63:0] s1_product; 
    reg        s1_valid;

    reg [31:0] s2_result; // Stage 2 Result (Final)
    reg        s2_valid;

    // Sink Ready Logic:
    // We are ready if S1 is invalid (empty) OR if S1 is moving to S2 (S2 ready/moving).
    // Let's use a standard pipeline structure.
    
    // NOTE: Simple pipeline without FIFOs can lock up if not careful. 
    // Strategy: Only advance if downstream is ready.
    
    wire s1_enable = (!s1_valid) || ( (!s2_valid) || aso_ready ); 
    // Logic: Enable S1 capture if:
    // 1. S1 is empty (can accept new)
    // 2. OR S1 can move to S2 (S2 is empty OR S2 can output)

    assign asi_ready = s1_enable;

    // Stage 1: Capture Input -> Multiply
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            s1_valid   <= 1'b0;
            s1_product <= 64'd0;
        end else if (s1_enable) begin
            s1_valid   <= asi_valid; // Capture valid state
            if (asi_valid) begin
                s1_product <= (asi_data * coeff_a); // 32x32=64 mult
            end
        end
    end

    // Stage 2: Shift-Add Division (/400)
    // Trigger condition: S1 is valid. We move S1->S2 if S2 is enabled.
    
    wire s2_enable = (!s2_valid) || aso_ready;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            s2_valid  <= 1'b0;
            s2_result <= 32'd0;
        end else if (s2_enable) begin
            s2_valid <= s1_valid;
            if (s1_valid) begin
                // Logic from my_multi_calc.v:
                // ((mult_stage << 10) + (mult_stage << 8) + (mult_stage << 5) - mult_stage) >> 19
                // Here, mult_stage is s1_product
                s2_result <= ((s1_product << 10) + (s1_product << 8) + (s1_product << 5) - s1_product) >> 19;
            end
        end
    end

    // Output Assignment
    assign aso_valid = s2_valid;
    assign aso_data  = s2_result;

endmodule
