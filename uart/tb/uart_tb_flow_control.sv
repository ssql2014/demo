`timescale 1ns / 1ps

module uart_tb_flow_control;
    uart_tb_base #(.TESTCASE_ID(7), .HAS_RTS_CTS(1'b1)) tb();
endmodule
