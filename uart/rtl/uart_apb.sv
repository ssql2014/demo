module uart_apb #(
    parameter int APB_ADDR_WIDTH = 6,
    parameter int FIFO_DEPTH = 16,
    parameter int DEFAULT_OSR = 16,
    parameter bit FRACTIONAL_BAUD = 1'b1,
    parameter bit HAS_RTS_CTS = 1'b0,
    parameter int SYNC_STAGES = 2
) (
    input  logic                         PCLK,
    input  logic                         PRESETn,
    input  logic                         PSEL,
    input  logic                         PENABLE,
    input  logic                         PWRITE,
    input  logic [APB_ADDR_WIDTH-1:0]    PADDR,
    input  logic [31:0]                  PWDATA,
    output logic [31:0]                  PRDATA,
    output logic                         PREADY,
    output logic                         PSLVERR,
    output logic                         TXD,
    input  logic                         RXD,
    output logic                         IRQ,
    output logic                         RTS,
    input  logic                         CTS
);

    localparam logic [APB_ADDR_WIDTH-1:0] ADDR_DATA       = 'h00;
    localparam logic [APB_ADDR_WIDTH-1:0] ADDR_STATUS     = 'h04;
    localparam logic [APB_ADDR_WIDTH-1:0] ADDR_CTRL       = 'h08;
    localparam logic [APB_ADDR_WIDTH-1:0] ADDR_BAUD       = 'h0C;
    localparam logic [APB_ADDR_WIDTH-1:0] ADDR_FIFO_CTRL  = 'h10;
    localparam logic [APB_ADDR_WIDTH-1:0] ADDR_INT_STATUS = 'h14;
    localparam logic [APB_ADDR_WIDTH-1:0] ADDR_INT_ENABLE = 'h18;
    localparam logic [APB_ADDR_WIDTH-1:0] ADDR_INT_CLEAR  = 'h1C;
    localparam logic [APB_ADDR_WIDTH-1:0] ADDR_FIFO_LEVEL = 'h20;
    localparam logic [APB_ADDR_WIDTH-1:0] ADDR_VERSION    = 'h24;

    localparam int VERSION_VALUE = 32'h0110_2509;
    localparam int FIFO_LEVEL_W  = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH + 1);
    localparam int SYNC_LEN      = (SYNC_STAGES < 2) ? 2 : SYNC_STAGES;

    assign PREADY  = 1'b1;
    assign PSLVERR = 1'b0;

    logic [APB_ADDR_WIDTH-1:0] addr_q;
    logic                      write_q;

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            addr_q  <= '0;
            write_q <= 1'b0;
        end else if (PSEL && !PENABLE) begin
            addr_q  <= PADDR;
            write_q <= PWRITE;
        end
    end

    wire setup_phase = PSEL && !PENABLE;
    wire access_phase = PSEL && PENABLE;
    wire apb_write = access_phase && write_q;
    wire apb_read  = access_phase && !write_q;
    wire apb_read_setup = setup_phase && !PWRITE;

    logic [31:0] reg_ctrl;
    logic [15:0] reg_baud_int;
    logic [7:0]  reg_baud_frac;
    logic [3:0]  reg_rx_trig;
    logic [3:0]  reg_tx_trig;
    logic [3:0]  reg_timeout_cfg;
    logic [7:0]  reg_int_enable;
    logic [7:0]  reg_int_status;

    logic        tx_werr_sticky;
    logic        fe_sticky;
    logic        pe_sticky;
    logic        oe_sticky;

    logic [31:0] prdata_reg;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [31:0] ctrl_mask(input logic [31:0] wdata);
        logic [31:0] val;
        val = '0;
        val[0]     = wdata[0];
        val[1]     = wdata[1];
        val[2]     = wdata[2];
        val[3]     = wdata[3];
        val[5:4]   = wdata[5:4];
        val[6]     = wdata[6];
        val[7]     = wdata[7];
        val[8]     = wdata[8];
        val[13:10] = wdata[13:10];
        ctrl_mask  = val;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            reg_ctrl        <= 32'h0000_0007;
            reg_baud_int    <= 16'd0;
            reg_baud_frac   <= 8'd0;
            reg_rx_trig     <= 4'd0;
            reg_tx_trig     <= 4'd0;
            reg_timeout_cfg <= 4'd0;
            reg_int_enable  <= 8'd0;
        end else if (apb_write) begin
            unique case (addr_q)
                ADDR_CTRL: begin
                    reg_ctrl <= ctrl_mask(PWDATA);
                end
                ADDR_BAUD: begin
                    reg_baud_int  <= PWDATA[15:0];
                    reg_baud_frac <= PWDATA[23:16];
                end
                ADDR_FIFO_CTRL: begin
                    reg_rx_trig     <= PWDATA[5:2];
                    reg_tx_trig     <= PWDATA[9:6];
                    reg_timeout_cfg <= PWDATA[13:10];
                end
                ADDR_INT_ENABLE: begin
                    reg_int_enable <= PWDATA[7:0];
                end
                default: ;
            endcase
        end
    end

    logic uart_en;
    logic rx_en;
    logic tx_en;
    logic loopback_en;
    logic [1:0] data_len_sel;
    logic data_len_7bit;
    logic parity_en;
    logic parity_odd;
    logic stop_2;
    logic [3:0] osr_sel;

    assign uart_en     = reg_ctrl[0];
    assign rx_en       = reg_ctrl[1];
    assign tx_en       = reg_ctrl[2];
    assign loopback_en = reg_ctrl[3];
    assign data_len_sel = reg_ctrl[5:4];
    assign data_len_7bit = (data_len_sel == 2'b01);
    assign parity_en   = reg_ctrl[6];
    assign parity_odd  = reg_ctrl[7];
    assign stop_2      = reg_ctrl[8];
    assign osr_sel     = reg_ctrl[13:10];

    logic tx_fifo_wr_en;
    logic [7:0] tx_fifo_wr_data;
    logic tx_fifo_clr_pulse;
    logic rx_fifo_clr_pulse;
    assign tx_fifo_clr_pulse = apb_write && (addr_q == ADDR_FIFO_CTRL) && PWDATA[1];
    assign rx_fifo_clr_pulse = apb_write && (addr_q == ADDR_FIFO_CTRL) && PWDATA[0];

    logic rx_fifo_rd_en;
    assign rx_fifo_rd_en = apb_read_setup && (PADDR == ADDR_DATA);

    logic tx_write_attempt;
    assign tx_write_attempt = apb_write && (addr_q == ADDR_DATA);
    assign tx_fifo_wr_data  = PWDATA[7:0];

    logic tx_fifo_full;
    logic tx_fifo_empty;
    logic [FIFO_LEVEL_W-1:0] tx_fifo_level;
    logic tx_fifo_rd_en;
    logic [7:0] tx_fifo_rd_data;
    logic tx_fifo_rd_valid;

    logic rx_fifo_full;
    logic rx_fifo_empty;
    logic [FIFO_LEVEL_W-1:0] rx_fifo_level;
    logic [7:0] rx_fifo_rd_data;
    logic rx_fifo_rd_valid;
    logic rx_fifo_wr_en;
    logic [7:0] rx_fifo_wr_data;

    uart_fifo #(
        .DATA_WIDTH(8),
        .DEPTH(FIFO_DEPTH)
    ) u_tx_fifo (
        .clk      (PCLK),
        .rst_n    (PRESETn),
        .clear    (tx_fifo_clr_pulse),
        .rd_en    (tx_fifo_rd_en),
        .rd_data  (tx_fifo_rd_data),
        .rd_valid (tx_fifo_rd_valid),
        .wr_en    (tx_fifo_wr_en),
        .wr_data  (tx_fifo_wr_data),
        .full     (tx_fifo_full),
        .empty    (tx_fifo_empty),
        .level    (tx_fifo_level)
    );

    uart_fifo #(
        .DATA_WIDTH(8),
        .DEPTH(FIFO_DEPTH)
    ) u_rx_fifo (
        .clk      (PCLK),
        .rst_n    (PRESETn),
        .clear    (rx_fifo_clr_pulse),
        .rd_en    (rx_fifo_rd_en),
        .rd_data  (rx_fifo_rd_data),
        .rd_valid (rx_fifo_rd_valid),
        .wr_en    (rx_fifo_wr_en),
        .wr_data  (rx_fifo_wr_data),
        .full     (rx_fifo_full),
        .empty    (rx_fifo_empty),
        .level    (rx_fifo_level)
    );

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            tx_werr_sticky <= 1'b0;
        end else begin
            if (tx_write_attempt && tx_fifo_full) begin
                tx_werr_sticky <= 1'b1;
            end else if (tx_fifo_clr_pulse || !uart_en) begin
                tx_werr_sticky <= 1'b0;
            end
        end
    end

    assign tx_fifo_wr_en = tx_write_attempt && !tx_fifo_full;

    logic [7:0] rx_read_data;
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            rx_read_data <= 8'd0;
        end else if (rx_fifo_rd_valid) begin
            rx_read_data <= rx_fifo_rd_data;
        end else if (rx_fifo_rd_en && rx_fifo_empty) begin
            rx_read_data <= 8'd0;
        end
    end

    logic osr_tick;
    logic bit_tick;
    logic [7:0] osr_value;

    uart_baud_gen #(
        .DEFAULT_OSR    (DEFAULT_OSR),
        .FRACTIONAL_EN  (FRACTIONAL_BAUD)
    ) u_baud_gen (
        .clk       (PCLK),
        .rst_n     (PRESETn),
        .enable    (uart_en),
        .osr_sel   (osr_sel),
        .div_int   (reg_baud_int),
        .div_frac  (reg_baud_frac),
        .osr_tick  (osr_tick),
        .bit_tick  (bit_tick),
        .osr_value (osr_value)
    );

    logic tx_ready;
    logic tx_busy;
    logic tx_done_pulse;
    logic txd_int;

    uart_tx u_tx (
        .clk         (PCLK),
        .rst_n       (PRESETn),
        .enable      (uart_en),
        .tx_enable   (tx_en),
        .parity_enable(parity_en),
        .parity_odd  (parity_odd),
        .data_len_7bit(data_len_7bit),
        .stop_2      (stop_2),
        .bit_tick    (bit_tick),
        .data_valid  (tx_fifo_rd_valid),
        .data_in     (tx_fifo_rd_data),
        .data_ready  (tx_ready),
        .busy        (tx_busy),
        .txd         (txd_int),
        .tx_done     (tx_done_pulse)
    );

    assign TXD = txd_int;

    logic cts_allow;
    assign cts_allow = (HAS_RTS_CTS) ? CTS : 1'b1;

    assign tx_fifo_rd_en = (uart_en && tx_en && tx_ready && !tx_fifo_empty && cts_allow);

    generate
        if (HAS_RTS_CTS) begin : gen_rts
            assign RTS = (rx_fifo_level < FIFO_DEPTH - 1);
        end else begin : gen_rts_tie
            assign RTS = 1'b1;
        end
    endgenerate

    logic rx_sample_in;
    assign rx_sample_in = loopback_en ? txd_int : RXD;

    logic [SYNC_LEN-1:0] rxd_sync_shift;
    integer i;
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            rxd_sync_shift <= {SYNC_LEN{1'b1}};
        end else begin
            rxd_sync_shift[0] <= rx_sample_in;
            for (i = 1; i < SYNC_LEN; i++) begin
                rxd_sync_shift[i] <= rxd_sync_shift[i-1];
            end
        end
    end

    wire rxd_sync = rxd_sync_shift[SYNC_LEN-1];

    logic [7:0] rx_data_word;
    logic rx_data_valid;
    logic rx_busy;
    logic rx_fe_pulse;
    logic rx_pe_pulse;

    uart_rx u_rx (
        .clk           (PCLK),
        .rst_n         (PRESETn),
        .enable        (uart_en),
        .rx_enable     (rx_en),
        .parity_enable (parity_en),
        .parity_odd    (parity_odd),
        .data_len_7bit (data_len_7bit),
        .stop_2        (stop_2),
        .osr_tick      (osr_tick),
        .osr_value     (osr_value),
        .rxd           (rxd_sync),
        .data_out      (rx_data_word),
        .data_valid    (rx_data_valid),
        .framing_error (rx_fe_pulse),
        .parity_error  (rx_pe_pulse),
        .busy          (rx_busy)
    );

    logic rx_oe_pulse;
    assign rx_fifo_wr_data = rx_data_word;
    assign rx_fifo_wr_en   = rx_data_valid && !rx_fifo_full;
    assign rx_oe_pulse     = rx_data_valid && rx_fifo_full;

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            fe_sticky <= 1'b0;
            pe_sticky <= 1'b0;
            oe_sticky <= 1'b0;
        end else begin
            logic fe_next;
            logic pe_next;
            logic oe_next;

            fe_next = fe_sticky;
            pe_next = pe_sticky;
            oe_next = oe_sticky;

            if (rx_fifo_clr_pulse || !uart_en) begin
                fe_next = 1'b0;
                pe_next = 1'b0;
                oe_next = 1'b0;
            end else begin
                if (apb_write && (addr_q == ADDR_INT_STATUS) && PWDATA[3]) fe_next = 1'b0;
                if (apb_write && (addr_q == ADDR_INT_STATUS) && PWDATA[4]) pe_next = 1'b0;
                if (apb_write && (addr_q == ADDR_INT_STATUS) && PWDATA[5]) oe_next = 1'b0;
                if (apb_write && (addr_q == ADDR_INT_CLEAR) && PWDATA[3]) fe_next = 1'b0;
                if (apb_write && (addr_q == ADDR_INT_CLEAR) && PWDATA[4]) pe_next = 1'b0;
                if (apb_write && (addr_q == ADDR_INT_CLEAR) && PWDATA[5]) oe_next = 1'b0;
                if (rx_fe_pulse) fe_next = 1'b1;
                if (rx_pe_pulse) pe_next = 1'b1;
                if (rx_oe_pulse) oe_next = 1'b1;
            end

            fe_sticky <= fe_next;
            pe_sticky <= pe_next;
            oe_sticky <= oe_next;
        end
    end

    logic [11:0] timeout_counter;
    logic [11:0] timeout_limit;
    logic [5:0]  char_bits;

    always_comb begin
        logic [4:0] data_bits_num;
        data_bits_num = data_len_7bit ? 5'd7 : 5'd8;
        char_bits = 6'd1 + data_bits_num + (parity_en ? 6'd1 : 6'd0) + (stop_2 ? 6'd2 : 6'd1);
    end

    always_comb begin
        timeout_limit = reg_timeout_cfg == 4'd0 ? 12'd0 : (reg_timeout_cfg * char_bits);
    end

    logic rx_timeout_event;
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            timeout_counter <= 12'd0;
            rx_timeout_event <= 1'b0;
        end else begin
            if (!uart_en || !rx_en || (reg_timeout_cfg == 4'd0) || rx_fifo_empty || rx_data_valid) begin
                timeout_counter <= 12'd0;
                rx_timeout_event <= 1'b0;
            end else if (bit_tick) begin
                if (timeout_counter < timeout_limit) begin
                    timeout_counter <= timeout_counter + 12'd1;
                end else begin
                    timeout_counter <= timeout_limit;
                    rx_timeout_event <= 1'b1;
                end
            end
        end
    end

    logic rx_trig_event;
    logic tx_trig_event;
    logic rx_done_event;
    logic [FIFO_LEVEL_W-1:0] rx_trig_value;
    logic [FIFO_LEVEL_W-1:0] tx_trig_value;

    assign rx_trig_value = FIFO_LEVEL_W'(reg_rx_trig);
    assign tx_trig_value = FIFO_LEVEL_W'(reg_tx_trig);

    assign rx_trig_event = (reg_rx_trig != 4'd0) && (rx_fifo_level >= rx_trig_value);
    assign tx_trig_event = (reg_tx_trig != 4'd0) && (tx_fifo_level <= tx_trig_value);
    assign rx_done_event = rx_fifo_wr_en;

    logic [7:0] int_set_mask;
    always_comb begin
        int_set_mask = 8'd0;
        if (rx_trig_event)    int_set_mask[0] = 1'b1;
        if (tx_trig_event)    int_set_mask[1] = 1'b1;
        if (rx_timeout_event) int_set_mask[2] = 1'b1;
        if (rx_fe_pulse)      int_set_mask[3] = 1'b1;
        if (rx_pe_pulse)      int_set_mask[4] = 1'b1;
        if (rx_oe_pulse)      int_set_mask[5] = 1'b1;
        if (rx_done_event)    int_set_mask[6] = 1'b1;
        if (tx_done_pulse)    int_set_mask[7] = 1'b1;
    end

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            reg_int_status <= 8'd0;
        end else begin
            logic [7:0] next_status;
            next_status = reg_int_status | int_set_mask;
            if (apb_write && (addr_q == ADDR_INT_STATUS)) begin
                next_status &= ~PWDATA[7:0];
            end else if (apb_write && (addr_q == ADDR_INT_CLEAR)) begin
                next_status &= ~PWDATA[7:0];
            end
            reg_int_status <= next_status;
        end
    end

    assign IRQ = |(reg_int_status & reg_int_enable);

    logic [31:0] status_word;
    always_comb begin
        status_word = 32'd0;
        status_word[0]  = !rx_fifo_empty;
        status_word[1]  = tx_fifo_empty;
        status_word[2]  = rx_fifo_full;
        status_word[3]  = tx_fifo_full;
        status_word[4]  = rx_busy;
        status_word[5]  = tx_busy;
        status_word[6]  = fe_sticky | pe_sticky | oe_sticky;
        status_word[7]  = (!rx_busy) && (!tx_busy) && tx_fifo_empty;
        status_word[8]  = fe_sticky;
        status_word[9]  = pe_sticky;
        status_word[10] = oe_sticky;
        status_word[11] = tx_werr_sticky;
    end

    logic [7:0] fifo_depth_field;
    assign fifo_depth_field = (FIFO_DEPTH > 255) ? 8'd255 : FIFO_DEPTH[7:0];

    logic [7:0] rx_level_byte;
    logic [7:0] tx_level_byte;

    generate
        if (FIFO_LEVEL_W >= 8) begin : gen_lvl_sat
            assign rx_level_byte = (rx_fifo_level > 8'd255) ? 8'd255 : rx_fifo_level[7:0];
            assign tx_level_byte = (tx_fifo_level > 8'd255) ? 8'd255 : tx_fifo_level[7:0];
        end else begin : gen_lvl_ext
            assign rx_level_byte = {{(8-FIFO_LEVEL_W){1'b0}}, rx_fifo_level};
            assign tx_level_byte = {{(8-FIFO_LEVEL_W){1'b0}}, tx_fifo_level};
        end
    endgenerate

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            prdata_reg <= 32'd0;
        end else if (apb_read) begin
            unique case (addr_q)
                ADDR_DATA: begin
                    prdata_reg <= {24'd0, rx_fifo_rd_valid ? rx_fifo_rd_data : rx_read_data};
                end
                ADDR_STATUS: begin
                    prdata_reg <= status_word;
                end
                ADDR_CTRL: begin
                    prdata_reg <= reg_ctrl;
                end
                ADDR_BAUD: begin
                    prdata_reg <= {8'd0, reg_baud_frac, reg_baud_int};
                end
                ADDR_FIFO_CTRL: begin
                    prdata_reg <= {8'd0, fifo_depth_field, 2'b00, reg_timeout_cfg, reg_tx_trig, reg_rx_trig, 2'b00};
                end
                ADDR_INT_STATUS: begin
                    prdata_reg <= {24'd0, reg_int_status};
                end
                ADDR_INT_ENABLE: begin
                    prdata_reg <= {24'd0, reg_int_enable};
                end
                ADDR_FIFO_LEVEL: begin
                    prdata_reg <= {16'd0, tx_level_byte, rx_level_byte};
                end
                ADDR_VERSION: begin
                    prdata_reg <= VERSION_VALUE;
                end
                default: begin
                    prdata_reg <= 32'd0;
                end
            endcase
        end
    end

    assign PRDATA = prdata_reg;

endmodule
