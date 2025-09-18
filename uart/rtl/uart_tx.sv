module uart_tx (
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    input  logic tx_enable,
    input  logic parity_enable,
    input  logic parity_odd,
    input  logic data_len_7bit,
    input  logic stop_2,
    input  logic bit_tick,
    input  logic data_valid,
    input  logic [7:0] data_in,
    output logic data_ready,
    output logic busy,
    output logic txd,
    output logic tx_done
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_START,
        ST_DATA,
        ST_PARITY,
        ST_STOP1,
        ST_STOP2
    } state_t;

    state_t state;
    logic [3:0] bit_index;
    logic [7:0] shift_reg;
    logic       parity_bit;
    logic       txd_reg;
    logic       tx_done_reg;

    logic [3:0] data_bits;
    assign data_bits = data_len_7bit ? 4'd7 : 4'd8;

    assign busy       = (state != ST_IDLE);
    assign data_ready = enable && tx_enable && (state == ST_IDLE);
    assign txd        = txd_reg;
    assign tx_done    = tx_done_reg;

    function automatic logic compute_parity(input logic [7:0] data,
                                            input logic        data_len_is_7bit,
                                            input logic        odd);
        logic parity;
        parity = data_len_is_7bit ? ^data[6:0] : ^data;
        compute_parity = odd ? ~parity : parity;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            bit_index   <= '0;
            shift_reg   <= '0;
            parity_bit  <= 1'b0;
            txd_reg     <= 1'b1;
            tx_done_reg <= 1'b0;
        end else if (!enable || !tx_enable) begin
            state       <= ST_IDLE;
            bit_index   <= '0;
            txd_reg     <= 1'b1;
            tx_done_reg <= 1'b0;
        end else begin
            tx_done_reg <= 1'b0;
            case (state)
                ST_IDLE: begin
                    txd_reg <= 1'b1;
                    if (data_valid) begin
                        shift_reg  <= data_in;
                        parity_bit <= compute_parity(data_in, data_len_7bit, parity_odd);
                        bit_index  <= 4'd0;
                        state      <= ST_START;
                    end
                end
                ST_START: begin
                    txd_reg <= 1'b0;
                    if (bit_tick) begin
                        state <= ST_DATA;
                    end
                end
                ST_DATA: begin
                    txd_reg <= shift_reg[0];
                    if (bit_tick) begin
                        shift_reg <= {1'b0, shift_reg[7:1]};
                        if (bit_index == data_bits - 4'd1) begin
                            state <= parity_enable ? ST_PARITY : ST_STOP1;
                        end
                        bit_index <= bit_index + 4'd1;
                    end
                end
                ST_PARITY: begin
                    txd_reg <= parity_bit;
                    if (bit_tick) begin
                        state <= ST_STOP1;
                    end
                end
                ST_STOP1: begin
                    txd_reg <= 1'b1;
                    if (bit_tick) begin
                        if (stop_2) begin
                            state <= ST_STOP2;
                        end else begin
                            state       <= ST_IDLE;
                            tx_done_reg <= 1'b1;
                        end
                    end
                end
                ST_STOP2: begin
                    txd_reg <= 1'b1;
                    if (bit_tick) begin
                        state       <= ST_IDLE;
                        tx_done_reg <= 1'b1;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
