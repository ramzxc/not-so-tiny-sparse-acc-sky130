// Simulation-only correction of proven reset reconvergence X-pessimism.
// check_icc2_reset.py exhaustively proves D=0 for every binary feedback/input
// assignment under these reset polarities. Do not force Q or SRAM contents.
// Release immediately if any reset polarity is inactive or unknown.
`define TT_ACT_CTRL user_project.core.host.accelerator.tpu_core_tpu.activation_flow_controller
always @(`TT_ACT_CTRL.rst or `TT_ACT_CTRL.HFSNET_9 or `TT_ACT_CTRL.HFSNET_10) begin
    if (`TT_ACT_CTRL.rst === 1'b1 &&
        `TT_ACT_CTRL.HFSNET_9 === 1'b0 &&
        `TT_ACT_CTRL.HFSNET_10 === 1'b1) begin
        force `TT_ACT_CTRL.n115 = 1'b0;
        force `TT_ACT_CTRL.n131 = 1'b0;
    end else begin
        release `TT_ACT_CTRL.n115;
        release `TT_ACT_CTRL.n131;
    end
end
`undef TT_ACT_CTRL
