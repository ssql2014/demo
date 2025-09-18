module uart_rx (
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    input  logic rx_enable,
    input  logic parity_enable,
    input  logic parity_odd,
    input  logic data_len_7bit,
    input  logic stop_2,
    input  logic osr_tick,
    input  logic [7:0] osr_value,
    input  logic rxd,
    output logic [7:0] data_out,
    output logic data_valid,
    output logic framing_error,
    output logic parity_error,
    output logic busy
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_START,
        ST_DATA,
        ST_PARITY,
        ST_STOP
    } state_t;

    state_t state;
    logic [7:0] sample_reg;
    logic [3:0] bit_index;
    logic [7:0] phase_cnt;
    logic [7:0] sample_cnt;
    logic [7:0] osr_mid;
    logic       parity_calc;
    logic [1:0] stop_count;
    logic       rxd_q;
    logic       start_edge;

    logic [3:0] data_bits;
    assign data_bits = data_len_7bit ? 4'd7 : 4'd8;

    assign osr_mid = osr_value >> 1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_q <= 1'b1;
        end else begin
            rxd_q <= rxd;
        end
    end

    assign start_edge = (rxd_q == 1'b1) && (rxd == 1'b0);

    assign busy    = (state != ST_IDLE);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            sample_reg    <= '0;
            bit_index     <= '0;
            phase_cnt     <= '0;
            sample_cnt    <= '0;
            parity_calc   <= 1'b0;
            stop_count    <= '0;
            data_out      <= '0;
            data_valid    <= 1'b0;
            framing_error <= 1'b0;
            parity_error  <= 1'b0;
        end else begin
            data_valid    <= 1'b0;
            framing_error <= 1'b0;
            parity_error  <= 1'b0;

            if (!enable || !rx_enable) begin
                state      <= ST_IDLE;
                    phase_cnt  <= '0;
                    sample_cnt <= '0;
                    bit_index  <= '0;
                    parity_calc <= 1'b0;
            end

            case (state)
                ST_IDLE: begin
                    phase_cnt   <= '0;
                    bit_index   <= '0;
                    parity_calc <= 1'b0;
                    if (enable && rx_enable && start_edge) begin
                        state <= ST_START;
                    end
                end
                ST_START: begin
                    if (osr_tick) begin
                        phase_cnt <= phase_cnt + 8'd1;
                        if (phase_cnt == osr_mid - 8'd1) begin
                            if (rxd == 1'b0) begin
                                sample_reg  <= '0;
                                phase_cnt   <= 8'd0;
                            bit_index   <= 4'd0;
                            parity_calc <= 1'b0;
                            sample_cnt  <= osr_value - 8'd1;
                            state       <= ST_DATA;
                            end else begin
                                state <= ST_IDLE;
                            end
                        end
                    end
                end
                ST_DATA: begin
                    if (osr_tick) begin
                        if (sample_cnt == 8'd0) begin
                            sample_reg[bit_index[2:0]] <= rxd;
                            parity_calc <= parity_calc ^ rxd;
                            sample_cnt  <= osr_value - 8'd1;
                            if (bit_index == data_bits - 4'd1) begin
                                if (parity_enable) begin
                                    state <= ST_PARITY;
                                end else begin
                                    stop_count <= 2'd0;
                                    state <= ST_STOP;
                                end
                            end else begin
                                bit_index <= bit_index + 4'd1;
                            end
                        end else begin
                            sample_cnt <= sample_cnt - 8'd1;
                        end
                    end
                end
                ST_PARITY: begin
                    if (osr_tick) begin
                        if (sample_cnt == 8'd0) begin
                            logic sampled_parity;
                            logic expected;
                            sampled_parity = rxd;
                            sample_cnt    <= osr_value - 8'd1;
                            stop_count    <= 2'd0;
                            state         <= ST_STOP;
                            if (parity_enable) begin
                                expected = parity_odd ? ~parity_calc : parity_calc;
                                if (sampled_parity != expected) begin
                                    parity_error <= 1'b1;
                                end
                            end
                        end else begin
                            sample_cnt <= sample_cnt - 8'd1;
                        end
                    end
                end
                ST_STOP: begin
                    if (osr_tick) begin
                        if (sample_cnt == 8'd0) begin
                            if (rxd == 1'b0) begin
                                framing_error <= 1'b1;
                            end
                            if (stop_2 && (stop_count == 2'd0)) begin
                                stop_count <= 2'd1;
                                sample_cnt <= osr_value - 8'd1;
                            end else begin
                                state      <= ST_IDLE;
                                data_out   <= sample_reg;
                                data_valid <= 1'b1;
                            end
                        end else begin
                            sample_cnt <= sample_cnt - 8'd1;
                        end
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
