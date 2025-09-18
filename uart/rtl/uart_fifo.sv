// UART synchronous FIFO with clear and level reporting
module uart_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    clear,
    input  logic                    rd_en,
    output logic [DATA_WIDTH-1:0]   rd_data,
    output logic                    rd_valid,
    input  logic                    wr_en,
    input  logic [DATA_WIDTH-1:0]   wr_data,
    output logic                    full,
    output logic                    empty,
    output logic [$clog2(DEPTH+1)-1:0] level
);

    localparam int ADDR_WIDTH   = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam int LEVEL_WIDTH  = $clog2(DEPTH + 1);
    localparam logic [LEVEL_WIDTH-1:0] DEPTH_CONST = LEVEL_WIDTH'(DEPTH);
    localparam logic [ADDR_WIDTH-1:0] DEPTH_M1     = ADDR_WIDTH'(DEPTH-1);

    logic [DATA_WIDTH-1:0] mem   [DEPTH-1:0];
    logic [ADDR_WIDTH-1:0] rd_ptr;
    logic [ADDR_WIDTH-1:0] wr_ptr;
    logic [LEVEL_WIDTH-1:0] cnt;
    logic rd_fire;
    logic wr_fire;

    assign empty    = (cnt == 0);
    assign full     = (cnt == DEPTH_CONST);
    assign level    = cnt;
    assign rd_fire  = rd_en && !empty;
    assign wr_fire  = wr_en && !full;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr  <= '0;
            wr_ptr  <= '0;
            cnt     <= '0;
            rd_data <= '0;
            rd_valid <= 1'b0;
        end else begin
            if (clear) begin
                rd_ptr  <= '0;
                wr_ptr  <= '0;
                cnt     <= '0;
                rd_data <= '0;
                rd_valid <= 1'b0;
            end else begin
                rd_valid <= rd_fire;
                if (wr_fire) begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr <= (wr_ptr == DEPTH_M1) ? '0 : wr_ptr + 1'b1;
                end
                if (rd_fire) begin
                    rd_data <= mem[rd_ptr];
                    rd_ptr <= (rd_ptr == DEPTH_M1) ? '0 : rd_ptr + 1'b1;
                end
                case ({wr_fire, rd_fire})
                    2'b10: cnt <= cnt + 1'b1;
                    2'b01: cnt <= cnt - 1'b1;
                    default: cnt <= cnt;
                endcase
            end
        end
    end
endmodule
