create_clock -name PCLK -period 20.0 [get_ports PCLK]
set_input_delay 2.0 -clock PCLK [all_inputs]
set_output_delay 2.0 -clock PCLK [all_outputs]
