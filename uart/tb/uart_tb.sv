`timescale 1ns / 1ps

module uart_tb;
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
    logic                         RXD;
    logic                         CTS;
    wire                          TXD;
    wire                          IRQ;
    wire                          RTS;

    // Clock generator
    always #(CLK_PERIOD/2) PCLK = ~PCLK;

    // Default assignments
    assign RXD = 1'b1; // Idle high (unused when loopback enabled)

    // DUT instance
    uart_apb #(
        .APB_ADDR_WIDTH (APB_ADDR_WIDTH)
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
        .RXD     (RXD),
        .IRQ     (IRQ),
        .RTS     (RTS),
        .CTS     (CTS)
    );

    // Simple APB master model ------------------------------------------------
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

    // Scoreboard storage -----------------------------------------------------
    byte expected_q[$];
    logic [31:0] status_word;
    byte pattern [0:3];

    task automatic push_tx_byte(input byte value);
        begin
            expected_q.push_back(value);
            apb_write(6'h00, {24'd0, value});
        end
    endtask

    task automatic pop_and_check();
        byte exp;
        byte got;
        logic [31:0] data_word;
        begin
            if (expected_q.size() == 0) begin
                $fatal(1, "RX FIFO produced unexpected byte");
            end
            apb_read(6'h00, data_word);
            got = data_word[7:0];
            exp = expected_q[0];
            if (got !== exp) begin
                $fatal(1, "Mismatch: expected %02x got %02x", exp, got);
            end else begin
                $display("[%0t] RX matched byte 0x%02x", $time, got);
            end
            void'(expected_q.pop_front());
        end
    endtask

    task automatic wait_for_rx_bytes(input int count);
        int received;
        int guard;
        logic [31:0] status;
        logic [31:0] int_status;
        begin
            received = 0;
            guard    = 0;
            while (received < count) begin
                if (guard > 100000) begin
                    $fatal(1, "Timeout waiting for %0d bytes (got %0d)", count, received);
                end
                guard++;

                apb_read(6'h14, int_status); // INT_STATUS
                if (int_status != 0) begin
                    apb_write(6'h14, int_status); // clear handled interrupts
                end

                apb_read(6'h04, status); // STATUS
                if (status[0]) begin // RX_NONEMPTY
                    pop_and_check();
                    received++;
                end
            end
        end
    endtask

    // Test sequence ----------------------------------------------------------
    initial begin
        CTS = 1'b1;
        apb_idle();
        PRESETn = 1'b0;
        repeat (10) @(negedge PCLK);
        PRESETn = 1'b1;

        // Program baud and FIFO thresholds
        apb_write(6'h0C, 32'h0000_0010);           // BAUD: DIV_INT=16
        apb_write(6'h10, 32'h0000_0004);           // FIFO_CTRL: RX_TRIG=1
        apb_write(6'h18, 32'h0000_0041);           // INT_ENABLE: RX_TRIG + RX_DONE

        // Enable UART with loopback
        apb_write(6'h08, 32'h0000_000F);           // CTRL: enable, RX_EN, TX_EN, loopback

        // Send a pattern through TX FIFO
        pattern[0] = 8'h55;
        pattern[1] = 8'hA5;
        pattern[2] = 8'h5A;
        pattern[3] = 8'hFF;
        for (int idx = 0; idx < 4; idx++) begin
            push_tx_byte(pattern[idx]);
            wait_for_rx_bytes(1);
        end

        $display("[%0t] All bytes looped back correctly", $time);

        // Sanity check: FIFOs empty
        apb_read(6'h04, status_word);
        if (!status_word[1]) begin
            $fatal(1, "TX_EMPTY flag not set at end of test");
        end
        if (status_word[0]) begin
            $fatal(1, "RX FIFO not empty at end of test");
        end

        $display("UART smoke test PASSED");
        $finish;
    end
endmodule
