`timescale 1ns / 1ps

module uart_tb_base #(
    parameter int TESTCASE_ID = 0,
    parameter bit HAS_RTS_CTS = 1'b0
);
    localparam int APB_ADDR_WIDTH = 6;
    localparam time CLK_PERIOD    = 20ns; // 50 MHz

    // APB signals
    logic                         PCLK = 1'b0;
    logic                         PRESETn;
    logic                         PSEL;
    logic                         PENABLE;
    logic                         PWRITE;
    logic [APB_ADDR_WIDTH-1:0]    PADDR;
    logic [31:0]                  PWDATA;
    logic [31:0]                  PRDATA;
    logic                         PREADY;
    logic                         PSLVERR;

    // UART interface
    logic                         RXD_drv;
    logic                         CTS;
    wire                          TXD;
    wire                          IRQ;
    wire                          RTS;

    // Clock generator
    always #(CLK_PERIOD/2) PCLK = ~PCLK;

    // DUT instance
    uart_apb #(
        .APB_ADDR_WIDTH (APB_ADDR_WIDTH),
        .HAS_RTS_CTS    (HAS_RTS_CTS)
    ) dut (
        .PCLK    (PCLK),
        .PRESETn (PRESETn),
        .PSEL    (PSEL),
        .PENABLE (PENABLE),
        .PWRITE  (PWRITE),
        .PADDR   (PADDR),
        .PWDATA  (PWDATA),
        .PRDATA  (PRDATA),
        .PREADY  (PREADY),
        .PSLVERR (PSLVERR),
        .TXD     (TXD),
        .RXD     (RXD_drv),
        .IRQ     (IRQ),
        .RTS     (RTS),
        .CTS     (CTS)
    );

    // internal signals for convenience
    wire bit_tick = dut.bit_tick;

    initial RXD_drv = 1'b1;

    // ---------------------------------------------------------------------
    // APB master helpers
    task automatic apb_idle();
        begin
            PSEL    = 1'b0;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = '0;
            PWDATA  = '0;
        end
    endtask

    task automatic apb_write(input logic [APB_ADDR_WIDTH-1:0] addr,
                              input logic [31:0] data);
        begin
            @(negedge PCLK);
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b1;
            PADDR   = addr;
            PWDATA  = data;

            @(negedge PCLK);
            PENABLE = 1'b1;

            @(negedge PCLK);
            apb_idle();
        end
    endtask

    task automatic apb_read(input  logic [APB_ADDR_WIDTH-1:0] addr,
                             output logic [31:0]              data);
        begin
            @(negedge PCLK);
            PSEL    = 1'b1;
            PENABLE = 1'b0;
            PWRITE  = 1'b0;
            PADDR   = addr;

            @(negedge PCLK);
            PENABLE = 1'b1;

            @(posedge PCLK);
            #1 data = PRDATA;

            @(negedge PCLK);
            apb_idle();
        end
    endtask

    // ---------------------------------------------------------------------
    // Shared state
    byte expected_q[$];
    bit  scoreboard_enable;

    task automatic push_tx_byte(input byte value, input bit track = 1'b1);
        begin
            if (track) expected_q.push_back(value);
            apb_write(6'h00, {24'd0, value});
        end
    endtask

    task automatic pop_and_check();
        byte exp;
        byte got;
        logic [31:0] data_word;
        begin
            if (!scoreboard_enable) begin
                $fatal(1, "Scoreboard disabled but pop requested");
            end
            if (expected_q.size() == 0) begin
                $fatal(1, "RX FIFO produced unexpected byte");
            end
            apb_read(6'h00, data_word);
            got = data_word[7:0];
            exp = expected_q.pop_front();
            if (got !== exp) begin
                $fatal(1, "Mismatch: expected %02x got %02x", exp, got);
            end else begin
                $display("[%0t] RX matched byte 0x%02x", $time, got);
            end
        end
    endtask

    task automatic wait_for_rx_bytes(input int count);
        int received;
        int guard;
        logic [31:0] status;
        logic [31:0] int_status;
        begin
            if (!scoreboard_enable) begin
                $fatal(1, "Scoreboard disabled but wait_for_rx_bytes called");
            end
            received = 0;
            guard    = 0;
            while (received < count) begin
                if (guard > 100000) begin
                    $fatal(1, "Timeout waiting for %0d bytes (got %0d)", count, received);
                end
                guard++;

                apb_read(6'h14, int_status);
                if (int_status != 0) begin
                    apb_write(6'h14, int_status);
                end

                apb_read(6'h04, status);
                if (status[0]) begin
                    pop_and_check();
                    received++;
                end
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // Utility waiters
    task automatic wait_for_status_bit(input int bit_idx,
                                       input bit expected,
                                       input int max_iterations = 200000);
        int guard = 0;
        logic [31:0] status;
        begin : wait_status
            while (1) begin
                apb_read(6'h04, status);
                if (status[bit_idx] === expected)
                    disable wait_status;
                guard++;
                if (guard > max_iterations) begin
                    $fatal(1, "Timeout waiting for STATUS[%0d] == %0b (last=0x%08x)",
                           bit_idx, expected, status);
                end
            end
        end
    endtask

    task automatic wait_for_int_bit(input int bit_idx,
                                    input int max_iterations = 200000);
        int guard = 0;
        logic [31:0] int_status;
        begin : wait_int
            while (1) begin
                apb_read(6'h14, int_status);
                if (int_status[bit_idx]) begin
                    disable wait_int;
                end
                guard++;
                if (guard > max_iterations) begin
                    $fatal(1, "Timeout waiting for INT_STATUS[%0d] (last=0x%02x)",
                           bit_idx, int_status[7:0]);
                end
            end
        end
    endtask

    task automatic clear_ints(input logic [7:0] mask);
        begin
            if (mask != 8'd0)
                apb_write(6'h14, {24'd0, mask});
        end
    endtask

    task automatic wait_bit_ticks(input int count);
        begin
            for (int i = 0; i < count; i++) begin
                @(posedge bit_tick);
            end
        end
    endtask

    task automatic drive_rx_byte(input byte data,
                                 input bit force_parity_error,
                                 input bit parity_enable,
                                 input int stop_bits);
        bit parity;
        begin
            // ensure idle high before start
            RXD_drv = 1'b1;
            wait_bit_ticks(2);

            // start bit
            RXD_drv = 1'b0;
            wait_bit_ticks(1);

            for (int i = 0; i < 8; i++) begin
                RXD_drv = data[i];
                wait_bit_ticks(1);
            end

            if (parity_enable) begin
                parity = ^data;
                if (force_parity_error)
                    parity = ~parity;
                RXD_drv = parity;
                wait_bit_ticks(1);
            end

            RXD_drv = 1'b1;
            wait_bit_ticks(stop_bits);
        end
    endtask

    // ---------------------------------------------------------------------
    task automatic reset_dut();
        begin
            CTS      = 1'b1;
            RXD_drv  = 1'b1;
            apb_idle();
            expected_q.delete();
            scoreboard_enable = 1'b0;

            PRESETn = 1'b0;
            repeat (10) @(negedge PCLK);
            PRESETn = 1'b1;
            repeat (2) @(negedge PCLK);
        end
    endtask

    // ---------------------------------------------------------------------
    task automatic run_loopback();
        byte pattern [0:3];
        logic [31:0] status;
        begin
            reset_dut();
            scoreboard_enable = 1'b1;

            apb_write(6'h0C, 32'h0000_0010);           // BAUD: DIV_INT=16
            apb_write(6'h10, 32'h0000_0004);           // FIFO_CTRL: RX_TRIG=1
            apb_write(6'h18, 32'h0000_0041);           // INT_ENABLE: RX_TRIG + RX_DONE
            apb_write(6'h08, 32'h0000_000F);           // CTRL: enable, RX_EN, TX_EN, loopback

            pattern[0] = 8'h55;
            pattern[1] = 8'hA5;
            pattern[2] = 8'h5A;
            pattern[3] = 8'hFF;

            for (int idx = 0; idx < 4; idx++) begin
                push_tx_byte(pattern[idx], 1'b1);
                wait_for_rx_bytes(1);
            end

            apb_read(6'h04, status);
            if (!status[1]) $fatal(1, "TX_EMPTY flag not set after loopback");
            if (status[0])  $fatal(1, "RX_NONEMPTY flag set after draining FIFO");

            $display("[%0t] Loopback smoke test completed", $time);
        end
    endtask

    task automatic run_parity_error();
        logic [31:0] status;
        logic [31:0] int_status;
        logic [31:0] data_word;
        begin
            reset_dut();
            scoreboard_enable = 1'b0;

            apb_write(6'h0C, 32'h0000_0010); // BAUD: DIV_INT=16
            apb_write(6'h10, 32'h0000_0000); // FIFO_CTRL: defaults
            apb_write(6'h18, 32'h0000_0050); // INT_ENABLE: PE_INT (bit4) + RX_DONE (bit6)
            apb_write(6'h08, 32'h0000_0043); // CTRL: enable, RX_EN, parity enable, even parity
            clear_ints(8'hFF);

            wait_bit_ticks(4);
            drive_rx_byte(8'hC3, 1'b1, 1'b1, 1); // force parity error
            $display("[%0t] Drove byte 0xC3 with parity error", $time);

            wait_for_status_bit(0, 1'b1);
            apb_read(6'h04, status);
            $display("[%0t] Parity test STATUS=0x%08x", $time, status);
            wait_for_int_bit(4);
            apb_read(6'h04, status);
            apb_read(6'h14, int_status);

            if (!status[9]) begin
                $fatal(1, "Parity error flag not set in STATUS");
            end
            if (!int_status[4]) begin
                $fatal(1, "Parity error interrupt not set");
            end

            // clear interrupt and pop data to avoid residual state
            clear_ints(int_status[7:0]);
            apb_read(6'h00, data_word);
            $display("[%0t] Parity error test captured data 0x%02x", $time, data_word[7:0]);
        end
    endtask

    task automatic run_rx_overflow();
        logic [31:0] status;
        logic [31:0] int_status;
        logic [31:0] data_word;
        byte value;
        int depth = 28;
        begin
            reset_dut();
            scoreboard_enable = 1'b0;

            apb_write(6'h0C, 32'h0000_0010);
            apb_write(6'h10, 32'h0000_0000);
            apb_write(6'h18, 32'h0000_0020);
            apb_write(6'h08, 32'h0000_0003);
            clear_ints(8'hFF);

            wait_bit_ticks(4);
            for (int idx = 0; idx < depth; idx++) begin
                value = idx[7:0];
                drive_rx_byte(value, 1'b0, 1'b0, 1);
            end

            wait_for_status_bit(2, 1'b1, 5_000_000);
            wait_for_int_bit(5, 5_000_000);

            apb_read(6'h04, status);
            apb_read(6'h14, int_status);

            if (!status[10]) $fatal(1, "Overflow flag not set in STATUS");
            if (!int_status[5]) $fatal(1, "Overflow interrupt not set");

            clear_ints(int_status[7:0]);

            while (status[0]) begin
                apb_read(6'h00, data_word);
                apb_read(6'h04, status);
            end

            $display("[%0t] RX overflow test completed", $time);
        end
    endtask

    task automatic run_reg_access();
        logic [31:0] data;
        logic [7:0] status_before;
        begin
            reset_dut();
            scoreboard_enable = 1'b0;

            apb_read(6'h24, data);
            if (data !== 32'h0110_2509)
                $fatal(1, "VERSION mismatch: 0x%08x", data);

            apb_read(6'h08, data);
            if (data !== 32'h0000_0007)
                $fatal(1, "CTRL reset mismatch: 0x%08x", data);

            apb_read(6'h0C, data);
            if (data !== 32'h0000_0000)
                $fatal(1, "BAUD reset mismatch: 0x%08x", data);

            apb_read(6'h10, data);
            if (data[15:0] !== 16'h0000)
                $fatal(1, "FIFO_CTRL reset mismatch (low bits): 0x%08x", data);
            if (data[23:16] == 8'd0)
                $fatal(1, "FIFO_CTRL depth field unexpected: 0x%08x", data);

            apb_read(6'h18, data);
            if (data !== 32'h0000_0000)
                $fatal(1, "INT_ENABLE reset mismatch: 0x%08x", data);

            apb_read(6'h20, data);
            if (data[15:0] !== 16'h0000)
                $fatal(1, "FIFO_LEVEL not zero after reset: 0x%08x", data);

            apb_write(6'h08, 32'h0000_01C3);
            apb_read(6'h08, data);
            if (data !== 32'h0000_01C3)
                $fatal(1, "CTRL write/read mismatch: 0x%08x", data);

            apb_write(6'h0C, 32'h0001_0020);
            apb_read(6'h0C, data);
            if (data !== 32'h0001_0020)
                $fatal(1, "BAUD write/read mismatch: 0x%08x", data);

            apb_write(6'h10, 32'h0000_24C4);
            apb_read(6'h10, data);
            if (data[15:0] !== 16'h24C4)
                $fatal(1, "FIFO_CTRL write/read mismatch (low bits): 0x%08x", data);

            apb_write(6'h18, 32'h0000_00AA);
            apb_read(6'h18, data);
            if (data !== 32'h0000_00AA)
                $fatal(1, "INT_ENABLE write/read mismatch: 0x%08x", data);

            apb_read(6'h14, data);
            status_before = data[7:0];
            apb_write(6'h14, {24'd0, status_before});
            apb_read(6'h14, data);
            if ((data[7:0] & ~status_before) !== 8'h00)
                $fatal(1, "INT_STATUS write1clear introduced new bits: 0x%08x", data);

            apb_write(6'h1C, {24'd0, status_before});
            apb_read(6'h14, data);
            if ((data[7:0] & ~status_before) !== 8'h00)
                $fatal(1, "INT_CLEAR introduced new bits: 0x%08x", data);

            $display("[%0t] Register access test completed", $time);
        end
    endtask

    task automatic run_stop_bits();
        logic [31:0] status;
        logic [31:0] int_status;
        logic [31:0] data_word;
        begin
            reset_dut();
            scoreboard_enable = 1'b0;

            apb_write(6'h0C, 32'h0000_0010);
            apb_write(6'h18, 32'h0000_0008);
            apb_write(6'h08, 32'h0000_0103);
            clear_ints(8'hFF);

            drive_rx_byte(8'hA5, 1'b0, 1'b0, 1);
            RXD_drv = 1'b0;
            wait_bit_ticks(1);
            RXD_drv = 1'b1;
            wait_bit_ticks(1);
            wait_for_int_bit(3, 5_000_000);
            apb_read(6'h04, status);
            apb_read(6'h14, int_status);
            if (!status[8]) $fatal(1, "Framing error not detected for short stop");
            if (!int_status[3]) $fatal(1, "Framing interrupt missing");
            clear_ints(int_status[7:0]);

            drive_rx_byte(8'h3C, 1'b0, 1'b0, 2);
            wait_for_status_bit(0, 1'b1, 5_000_000);
            apb_read(6'h04, status);
            if (status[8]) $fatal(1, "Unexpected framing error on correct stop bits");
            apb_read(6'h00, data_word);
            $display("[%0t] Stop-bit test captured 0x%02x", $time, data_word[7:0]);
        end
    endtask

    task automatic run_rx_timeout();
        logic [31:0] status;
        logic [31:0] int_status;
        begin
            reset_dut();
            scoreboard_enable = 1'b0;

            apb_write(6'h0C, 32'h0000_0010);
            apb_write(6'h10, 32'h0000_0400);
            apb_write(6'h18, 32'h0000_0004);
            apb_write(6'h08, 32'h0000_0003);
            clear_ints(8'hFF);

            wait_bit_ticks(4);
            drive_rx_byte(8'h5A, 1'b0, 1'b0, 1);

            wait_for_int_bit(2, 5_000_000);
            apb_read(6'h14, int_status);
            if (!int_status[2]) $fatal(1, "Timeout interrupt not observed");
            apb_read(6'h04, status);
            if (!status[0]) $fatal(1, "RX FIFO expected non-empty during timeout");

            clear_ints(int_status[7:0]);
            while (status[0]) begin
                apb_read(6'h00, status);
                apb_read(6'h04, status);
            end

            $display("[%0t] RX timeout test completed", $time);
        end
    endtask

    task automatic measure_bit_cycles(output int cycles);
        cycles = 0;
        @(posedge bit_tick);
        @(negedge bit_tick);
        begin : wait_next_tick
            while (1) begin
                @(posedge PCLK);
                cycles++;
                if (bit_tick)
                    disable wait_next_tick;
            end
        end
    endtask

    task automatic run_baud_sweep();
        int cycles;
        begin
            reset_dut();
            scoreboard_enable = 1'b0;

            apb_write(6'h08, 32'h0000_0001);
            apb_write(6'h0C, 32'h0000_0010);
            repeat (5) @(posedge PCLK);
            measure_bit_cycles(cycles);
            if (cycles != 256) $fatal(1, "Baud sweep case0 mismatch: %0d", cycles);

            apb_write(6'h08, 32'h0000_0401);
            apb_write(6'h0C, 32'h0000_0008);
            repeat (5) @(posedge PCLK);
            measure_bit_cycles(cycles);
            if (cycles != 64) $fatal(1, "Baud sweep case1 mismatch: %0d", cycles);

            apb_write(6'h08, 32'h0000_0801);
            apb_write(6'h0C, 32'h0000_0004);
            repeat (5) @(posedge PCLK);
            measure_bit_cycles(cycles);
            if (cycles != 16) $fatal(1, "Baud sweep case2 mismatch: %0d", cycles);

            $display("[%0t] Baud sweep test completed", $time);
        end
    endtask

    task automatic run_flow_control();
        logic [31:0] status;
        logic [31:0] tmp;
        begin
            reset_dut();
            scoreboard_enable = 1'b0;

            apb_write(6'h0C, 32'h0000_0010);
            apb_write(6'h08, 32'h0000_0005);

            CTS = 1'b0;
            for (int i = 0; i < 4; i++) begin
                apb_write(6'h00, {24'd0, 8'hF0 + i});
            end

            repeat (200) @(posedge PCLK);
            apb_read(6'h04, status);
            if (status[5]) $fatal(1, "TX busy with CTS low");

            CTS = 1'b1;
            wait_for_status_bit(1, 1'b1, 5_000_000);

            apb_write(6'h08, 32'h0000_0007);
            clear_ints(8'hFF);
            for (int j = 0; j < 15; j++) begin
                drive_rx_byte(j[7:0], 1'b0, 1'b0, 1);
            end
            if (RTS !== 1'b0) $fatal(1, "RTS not deasserted when RX nearly full");

            apb_read(6'h04, status);
            while (status[0]) begin
                apb_read(6'h00, tmp);
                apb_read(6'h04, status);
            end
            if (RTS !== 1'b1) $fatal(1, "RTS not restored after draining RX");

            $display("[%0t] Flow-control test completed", $time);
        end
    endtask

    // ---------------------------------------------------------------------
    localparam int CASE_REG_RW        = 0;
    localparam int CASE_LOOPBACK     = 1;
    localparam int CASE_PARITY_ERR   = 2;
    localparam int CASE_STOP_BITS    = 3;
    localparam int CASE_RX_OVERFLOW  = 4;
    localparam int CASE_RX_TIMEOUT   = 5;
    localparam int CASE_BAUD_SWEEP   = 6;
    localparam int CASE_FLOW_CONTROL = 7;

    reg [8*24-1:0] test_name;

    initial begin
        case (TESTCASE_ID)
            CASE_REG_RW: begin
                test_name = "reg_access";
                run_reg_access();
            end
            CASE_LOOPBACK: begin
                test_name = "loopback";
                run_loopback();
            end
            CASE_PARITY_ERR: begin
                test_name = "parity_error";
                run_parity_error();
            end
            CASE_STOP_BITS: begin
                test_name = "stop_bits";
                run_stop_bits();
            end
            CASE_RX_OVERFLOW: begin
                test_name = "rx_overflow";
                run_rx_overflow();
            end
            CASE_RX_TIMEOUT: begin
                test_name = "rx_timeout";
                run_rx_timeout();
            end
            CASE_BAUD_SWEEP: begin
                test_name = "baud_sweep";
                run_baud_sweep();
            end
            CASE_FLOW_CONTROL: begin
                test_name = "flow_control";
                run_flow_control();
            end
            default: begin
                $fatal(1, "Unknown TESTCASE_ID %0d", TESTCASE_ID);
            end
        endcase

        $display("TEST %0s PASSED", test_name);
        $finish;
    end
endmodule
