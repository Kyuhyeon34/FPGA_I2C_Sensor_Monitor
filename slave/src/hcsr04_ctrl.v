`timescale 1ns / 1ps
//==============================================================================
// hcsr04_ctrl : HC-SR04 ultrasonic distance (cm)
//   - trig 10us every PERIOD_US, distance = echo_us / 58
//   - Echo is 5V on most modules : use a 1k/2k divider to the FPGA pin
//==============================================================================
module hcsr04_ctrl #(
    parameter CLK_PER_US = 100,
    parameter PERIOD_US  = 60_000,       // 60 ms
    parameter TRIG_US    = 10,
    parameter TIMEOUT_US = 30_000        // ~5 m
)(
    input             clk,
    input             reset,
    output reg        trig,
    input             echo,
    output reg [15:0] dist_cm,
    output reg        valid
);

    reg [1:0] echo_sync;
    always @(posedge clk) echo_sync <= {echo_sync[0], echo};
    wire e = echo_sync[1];

    reg [7:0] div;
    wire tick_us = (div == CLK_PER_US-1);
    always @(posedge clk or posedge reset) begin
        if (reset)        div <= 0;
        else if (tick_us) div <= 0;
        else              div <= div + 1'b1;
    end

    localparam S_IDLE = 2'd0, S_TRIG = 2'd1, S_WAIT_H = 2'd2, S_MEAS = 2'd3;

    reg [1:0]  state;
    reg [16:0] us_cnt;       // time in state / period
    reg [5:0]  cm_sub;       // 0..57 us
    reg [15:0] cm_cnt;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= S_IDLE; us_cnt <= 0; cm_sub <= 0; cm_cnt <= 0;
            trig <= 0; dist_cm <= 0; valid <= 0;
        end else begin
            case (state)
            S_IDLE: begin
                trig <= 0;
                if (tick_us) begin
                    if (us_cnt >= PERIOD_US-1) begin us_cnt <= 0; state <= S_TRIG; end
                    else us_cnt <= us_cnt + 1'b1;
                end
            end

            S_TRIG: begin
                trig <= 1;
                if (tick_us) begin
                    if (us_cnt >= TRIG_US-1) begin us_cnt <= 0; trig <= 0; state <= S_WAIT_H; end
                    else us_cnt <= us_cnt + 1'b1;
                end
            end

            S_WAIT_H: begin
                if (e) begin
                    us_cnt <= 0; cm_sub <= 0; cm_cnt <= 0; state <= S_MEAS;
                end else if (tick_us) begin
                    if (us_cnt >= TIMEOUT_US) begin us_cnt <= 0; valid <= 0; state <= S_IDLE; end
                    else us_cnt <= us_cnt + 1'b1;
                end
            end

            S_MEAS: begin
                if (!e) begin
                    dist_cm <= cm_cnt;
                    valid   <= 1'b1;
                    us_cnt  <= 0;
                    state   <= S_IDLE;
                end else if (tick_us) begin
                    us_cnt <= us_cnt + 1'b1;
                    if (cm_sub == 57) begin cm_sub <= 0; cm_cnt <= cm_cnt + 1'b1; end
                    else cm_sub <= cm_sub + 1'b1;
                    if (us_cnt >= TIMEOUT_US) begin us_cnt <= 0; valid <= 0; state <= S_IDLE; end
                end
            end
            endcase
        end
    end

endmodule
