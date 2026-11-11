import os
word_size = 64
num_words = 64
write_size = 64
num_rw_ports = 1
num_r_ports = 0
num_w_ports = 0
num_banks = 1
# Keep one unused spare column; the public wrapper exposes 64 usable bits.
num_spare_cols = 1
words_per_row = int(os.environ.get("TT_WORDS_PER_ROW", "2"))
local_array_size = 0
tech_name = "sky130"
tech_file = "tech_custom_cell"
use_nix = False
nominal_corner_only = True
process_corners = ["TT"]
supply_voltages = [1.8]
temperatures = [25]
check_lvsdrc = True
analytical_delay = True
perimeter_pins = False
# Preserve real routing geometry instead of blanket internal blockages.
detailed_lef = True
route_supplies = os.environ.get("TT_ROUTE_SUPPLIES", "1") == "1"
output_name = "tt_sram_1rw_64x64_sky130"
output_path = os.environ["TT_SRAM_OUTPUT"]
