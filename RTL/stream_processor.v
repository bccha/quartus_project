module stream_processor (
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-MM Slave (Control Interface)
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire        avs_read,
    output wire [31:0] avs_readdata,
    output reg         avs_readdatavalid,
    input  wire [1:0]  avs_address,  // Expanded to 2 bits for 4 registers

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
    
    // Hardware Version (increment this when you update RTL)
    localparam VERSION = 32'h0000_0103; // v1.03: 1-stage pipeline + bypass
    
    reg [31:0] coeff_a;
    reg        bypass;
    reg [31:0] in_count;
    reg [31:0] out_count;
    reg [31:0] avs_readdata_reg;
    
    // DEBUG: Signal activity counters
    reg [31:0] asi_valid_count;  // How many times asi_valid was high
    reg [31:0] aso_ready_count;  // How many times aso_ready was high

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
            
            // Read Logic (Align with my_slave.v pattern: 1-cycle latency)
            avs_readdatavalid <= avs_read;
            if (avs_read) begin
                case (avs_address)
                    2'b00: avs_readdata_reg <= coeff_a;
                    2'b01: avs_readdata_reg <= {31'd0, bypass};
                    2'b10: avs_readdata_reg <= asi_valid_count;  // DEBUG
                    // Address 2 is asi_valid_count
                    2'b11: avs_readdata_reg <= last_asi_data;    // DEBUG: Read last input
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

    // Single Pipeline Stage: Output Registers
    reg [31:0] aso_data_reg;
    reg        aso_valid_reg; // Corrected: 1-bit flag
    reg [31:0] last_asi_data; // DEBUG REGISTER
    
    // Intermediate variables for calculation
    reg [31:0] in_swapped;
    reg [31:0] res_calc;

    
    // Ready when output is ready or empty
    assign asi_ready = (!aso_valid_reg) || aso_ready;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            aso_valid_reg <= 1'b0;
            aso_data_reg  <= 32'd0;
            last_asi_data <= 32'd0;
        end else begin
            // Accept new data when ready and valid
            if (asi_ready && asi_valid) begin
                aso_valid_reg <= 1'b1;
                // Swap Input (Big Endian from DMA -> Little Endian for Calculation)
                // DMA sends [31:24] as Symbol 0 (which is LSB 0x90). So input is 0x90010000
                // We want 0x00000190.
                last_asi_data <= {asi_data[7:0], asi_data[15:8], asi_data[23:16], asi_data[31:24]}; 
                
                // STEP 2: Test with constant addition (no registers involved)
                if (bypass) begin
                    aso_data_reg <= asi_data; // Bypass: Pass-through (remains swapped)
                end else begin
                    // MULTIPLICATION MODE
                    // 1. Swap Input
                    in_swapped = {asi_data[7:0], asi_data[15:8], asi_data[23:16], asi_data[31:24]};
                    
                    // 2. Calculate (Use Reciprocal Multiplication for / 400)
                    // 1/400 ~= 0.0025. 5243 / 2^21 ~= 0.00250005
                    // This fits in a single cycle (unlike division)
                    res_calc = ((in_swapped * coeff_a) * 32'd5243) >> 21;
                    
                    // 3. Swap Output Back (Little Endian -> Big Endian for DMA)
                    aso_data_reg <= {res_calc[7:0], res_calc[15:8], res_calc[23:16], res_calc[31:24]};
                end
                
                in_count  <= in_count + 1;
                out_count <= out_count + 1;
            end else if (aso_ready && aso_valid_reg) begin
                // Output consumed, clear valid
                aso_valid_reg <= 1'b0;
            end
            // else: Keep current state (stall or hold)
        end
    end

    // Downstream Output Assignment
    assign aso_valid = aso_valid_reg;
    assign aso_data  = aso_data_reg;

endmodule

