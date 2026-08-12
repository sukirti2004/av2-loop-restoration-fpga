create_clock -period 6.667 -name clk [get_ports clk]
set_false_path -from [get_ports rst]