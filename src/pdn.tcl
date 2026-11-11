# Keep the standard Tiny Tapeout grid and add access to the OpenRAM met3 ring.
# The default macro connection is met4-to-met5, but TT routes power on met4.
source $::env(SCRIPTS_DIR)/openroad/common/pdn_cfg.tcl
add_pdn_connect -grid macro -layers {met3 met4}
