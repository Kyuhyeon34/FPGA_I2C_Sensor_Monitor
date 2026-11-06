`timescale 1ns / 1ps

module uart_tx #(
    parameter integer CLOCK_HZ = 100_000_000,
    parameter integer BAUD = 9600
)(
    input clk, input reset, input start, input [7:0] data,
    output reg tx, output reg busy
);
    localparam integer BIT_CYCLES = CLOCK_HZ / BAUD;
    localparam integer CW = (BIT_CYCLES < 2) ? 1 : $clog2(BIT_CYCLES);
    reg [CW-1:0] count;
    reg [9:0] frame;
    reg [3:0] bit_index;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tx <= 1;
            busy <= 0;
            count <= 0;
            frame <= 10'h3ff;
            bit_index <= 0;
        end else if (!busy) begin
            if (start) begin
                frame <= {1'b1, data, 1'b0};
                tx <= 0;
                busy <= 1;
                count <= 0;
                bit_index <= 0;
            end
        end else if (count == BIT_CYCLES - 1) begin
            count <= 0;
            if (bit_index == 9) begin
                tx <= 1;
                busy <= 0;
            end else begin
                bit_index <= bit_index + 1'b1;
                frame <= {1'b1, frame[9:1]};
                tx <= frame[1];
            end
        end else count <= count + 1'b1;
    end
endmodule
