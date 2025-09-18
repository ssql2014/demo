module uart_baud_gen #(
    parameter int DEFAULT_OSR = 16,
    parameter bit FRACTIONAL_EN = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    input  logic [3:0]  osr_sel,
    input  logic [15:0] div_int,
    input  logic [7:0]  div_frac,
    output logic        osr_tick,
    output logic        bit_tick,
    output logic [7:0]  osr_value
);

    function automatic logic [7:0] decode_osr(input logic [3:0] sel);
        case (sel)
            4'd0: decode_osr = 8'd16;
            4'd1: decode_osr = 8'd8;
            4'd2: decode_osr = 8'd4;
            default: decode_osr = DEFAULT_OSR_VAL;
        endcase
    endfunction

    localparam logic [7:0] DEFAULT_OSR_VAL = 8'(DEFAULT_OSR);

    logic [15:0] div_int_reg;
    logic [7:0]  div_frac_reg;
    logic [8:0]  frac_accum;
    logic [15:0] int_cnt;
    logic [7:0]  osr_val_reg;
    logic [7:0]  osr_phase;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_int_reg <= 16'd1;
            div_frac_reg <= 8'd0;
        end else begin
            div_int_reg <= (div_int == 16'd0) ? 16'd1 : div_int;
            div_frac_reg <= FRACTIONAL_EN ? div_frac : 8'd0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            osr_val_reg <= DEFAULT_OSR_VAL;
        end else begin
            osr_val_reg <= decode_osr(osr_sel);
        end
    end

    assign osr_value = osr_val_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int_cnt    <= 16'd1;
            frac_accum <= 9'd0;
            osr_phase  <= 8'd0;
            osr_tick   <= 1'b0;
            bit_tick   <= 1'b0;
        end else if (!enable) begin
            int_cnt    <= (div_int_reg > 0) ? div_int_reg - 1'b1 : 16'd0;
            frac_accum <= 9'd0;
            osr_phase  <= 8'd0;
            osr_tick   <= 1'b0;
            bit_tick   <= 1'b0;
        end else if (int_cnt == 16'd0) begin
            logic [8:0]  frac_sum;
            logic [15:0] next_reload;
            osr_tick <= 1'b1;
            bit_tick <= (osr_phase == osr_val_reg - 1'b1);
            if (osr_phase == osr_val_reg - 1'b1) begin
                osr_phase <= 8'd0;
            end else begin
                osr_phase <= osr_phase + 1'b1;
            end

            frac_sum    = frac_accum + div_frac_reg;
            next_reload = (div_int_reg == 16'd0) ? 16'd1 : div_int_reg;

            if (frac_sum >= 9'd256) begin
                frac_accum <= frac_sum - 9'd256;
                next_reload = next_reload + 16'd1;
            end else begin
                frac_accum <= frac_sum;
            end

            int_cnt <= (next_reload > 0) ? next_reload - 1'b1 : 16'd0;
        end else begin
            osr_tick <= 1'b0;
            bit_tick <= 1'b0;
            int_cnt  <= int_cnt - 1'b1;
        end
    end
endmodule
