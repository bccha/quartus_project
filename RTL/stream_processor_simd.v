`timescale 1ns / 1ps
module stream_processor_simd (
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-MM Slave (Control Interface)
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire        avs_read,
    output wire [31:0] avs_readdata,
    output reg         avs_readdatavalid,
    input  wire [1:0]  avs_address,

    // Avalon-ST Sink (128-bit Input)
    input  wire         asi_valid,
    input  wire [127:0] asi_data,  // 4 x 32-bit Data
    output wire         asi_ready,

    // Avalon-ST Source (128-bit Output)
    output wire         aso_valid,
    output wire [127:0] aso_data,  // 4 x 32-bit Data
    input  wire         aso_ready
);

    // --------------------------------------------------------
    // CSR (Control Status Register) Logic (Shared across lanes)
    // --------------------------------------------------------
    localparam VERSION = 32'h0001_0200; // v2.00: 128-bit SIMD Support
    
    reg [31:0] coeff_a;
    reg        bypass;
    reg [31:0] in_count;
    reg [31:0] out_count;
    reg [31:0] avs_readdata_reg;
    
    // Debug Counters
    reg [31:0] asi_valid_count;
    reg [31:0] aso_ready_count;

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
            
            // Read Logic
            avs_readdatavalid <= avs_read;
            if (avs_read) begin
                case (avs_address)
                    2'b00: avs_readdata_reg <= coeff_a;
                    2'b01: avs_readdata_reg <= {31'd0, bypass};
                    2'b10: avs_readdata_reg <= asi_valid_count;
                    2'b11: avs_readdata_reg <= 32'h514D_0128; // Marker (Ascii for SIMD + 128)
                endcase
            end
            
            if (asi_valid) asi_valid_count <= asi_valid_count + 1;
            if (aso_ready) aso_ready_count <= aso_ready_count + 1;
        end
    end

    // --------------------------------------------------------
    // N-Stage Pipeline Control (Shared)
    // --------------------------------------------------------
    parameter STAGES = 3;
    parameter LANES  = 4; // 128-bit / 32-bit = 4 Lanes

    reg [STAGES-1:0] pipe_valid;
    wire [STAGES:0]  pipe_ready;
    
    // Backpressure Chain
    assign pipe_ready[STAGES] = aso_ready;
    genvar i;
    generate
        for (i = 0; i < STAGES; i = i + 1) begin : gen_ready
            assign pipe_ready[i] = !pipe_valid[i] || pipe_ready[i+1];
        end
    endgenerate

    assign asi_ready = pipe_ready[0];

    // --------------------------------------------------------
    // SIMD Processing Lanes
    // --------------------------------------------------------
    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : simd_lane
            
            // Pipeline Registers per Lane
            reg [31:0] stage_data [0:STAGES-1];
            reg [63:0] intermediate_prod;
            reg [63:0] auto_res_calc; // internal reg

            // Lane Processing Logic
            always @(posedge clk or negedge reset_n) begin
                if (!reset_n) begin
                    stage_data[0] <= 32'd0;
                    stage_data[1] <= 32'd0;
                    stage_data[2] <= 32'd0;
                    intermediate_prod <= 64'd0;
                    auto_res_calc <= 64'd0;
                end else begin
                    
                    // --- [Stage 0]: Input Capture & Endian Swap ---
                    if (pipe_ready[0]) begin
                         if (asi_valid) begin
                            // Extract 32-bit chunk and swap endian
                            // Extract 32-bit chunk and swap endian from Little Endian (Avalon-ST) to Big Endian (Internal Math)
                            stage_data[0] <= {asi_data[lane*32 + 7  : lane*32 + 0 ],
                                              asi_data[lane*32 + 15 : lane*32 + 8 ],
                                              asi_data[lane*32 + 23 : lane*32 + 16],
                                              asi_data[lane*32 + 31 : lane*32 + 24]};
                        end
                    end

                    // --- [Stage 1]: Multiplication ---
                    if (pipe_ready[1]) begin
                        if (pipe_valid[0]) begin
                            if (bypass) begin
                                stage_data[1] <= stage_data[0];
                            end else begin
                                intermediate_prod <= (64'd1 * stage_data[0] * coeff_a);
                            end
                        end
                    end

                    // --- [Stage 2]: Shift-Add & Endian Restore ---
                    if (pipe_ready[2]) begin
                        if (pipe_valid[1]) begin
                            if (bypass) begin
                                // Reverse byte swap for output (Big Endian -> Little Endian)
                                stage_data[2] <= {stage_data[1][7:0], 
                                                  stage_data[1][15:8], 
                                                  stage_data[1][23:16], 
                                                  stage_data[1][31:24]};
                            end else begin
                                // Optimized Division: * 5243 >> 21
                                auto_res_calc = (intermediate_prod * 64'd5243) >> 21;
                                stage_data[2] <= {auto_res_calc[7:0], 
                                                  auto_res_calc[15:8], 
                                                  auto_res_calc[23:16], 
                                                  auto_res_calc[31:24]};
                            end
                        end
                    end
                end
            end
            
            // Assign Output Slice
            assign aso_data[lane*32 + 31 : lane*32] = stage_data[STAGES-1];
            
        end // end for lane
    endgenerate

    // --------------------------------------------------------
    // Pipeline Valid Control (Shared)
    // --------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pipe_valid <= {STAGES{1'b0}};
            in_count   <= 32'd0;
            out_count  <= 32'd0;
        end else begin
            // Stage 0 Valid
            if (pipe_ready[0]) begin
                pipe_valid[0] <= asi_valid;
                if (asi_valid) in_count <= in_count + 4; // 4 items at once
            end

            // Stage 1 Valid
            if (pipe_ready[1]) begin
                pipe_valid[1] <= pipe_valid[0];
            end

            // Stage 2 Valid
            if (pipe_ready[2]) begin
                pipe_valid[2] <= pipe_valid[1];
                if (pipe_valid[1]) out_count <= out_count + 4; // 4 items at once
            end
        end
    end

    assign aso_valid = pipe_valid[STAGES-1];

endmodule
