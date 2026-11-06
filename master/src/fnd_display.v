`timescale 1ns / 1ps

// Display four BCD digits with independently enabled decimal points.
module fnd_display #(
    parameter integer CLOCK_HZ = 100_000_000
)(
    input clk, input reset, input [15:0] bcd_data, input [3:0] dot_en,
    output reg [7:0] seg, output reg [3:0] an
);
    localparam integer SCAN_CYCLES = CLOCK_HZ / 1000;
    localparam integer CW = (SCAN_CYCLES < 2) ? 1 : $clog2(SCAN_CYCLES);
    reg [CW-1:0] count;
    reg [1:0] digit;
    reg [3:0] number;
    always @(posedge clk or posedge reset) begin
        if (reset) begin count <= 0; digit <= 0; end
        else if (count == SCAN_CYCLES - 1) begin
            count <= 0;
            digit <= digit + 1'b1;
        end else count <= count + 1'b1;
    end
    always @(*) begin
        an = ~(4'b0001 << digit);
        case (digit)
            0: number = bcd_data[3:0];
            1: number = bcd_data[7:4];
            2: number = bcd_data[11:8];
            default: number = bcd_data[15:12];
        endcase
        case (number)
            0: seg = 8'hc0;
            1: seg = 8'hf9;
            2: seg = 8'ha4;
            3: seg = 8'hb0;
            4: seg = 8'h99;
            5: seg = 8'h92;
            6: seg = 8'h82;
            7: seg = 8'hf8;
            8: seg = 8'h80;
            9: seg = 8'h90;
            default: seg = 8'hff;
        endcase
        seg[7] = ~dot_en[digit];
    end
endmodule
