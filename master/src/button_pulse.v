`timescale 1ns / 1ps

module button_pulse #(
    parameter integer STABLE_CYCLES = 1_000_000
)(
    input clk, input reset, input button,
    output reg pulse
);
    localparam integer CW = (STABLE_CYCLES < 2) ? 1 : $clog2(STABLE_CYCLES);
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_button;
    reg stable_button;
    reg [CW-1:0] count;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            sync_button <= 0;
            stable_button <= 0;
            count <= 0;
            pulse <= 0;
        end else begin
            sync_button <= {sync_button[0], button};
            pulse <= 0;
            if (sync_button[1] == stable_button) count <= 0;
            else if (count == STABLE_CYCLES - 1) begin
                stable_button <= sync_button[1];
                pulse <= sync_button[1];
                count <= 0;
            end else count <= count + 1'b1;
        end
    end
endmodule
