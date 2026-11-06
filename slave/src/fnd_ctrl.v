`timescale 1ns / 1ps
//==============================================================================
// fnd_ctrl : Basys3 4-digit 7-segment (active low)
//   mode 0 : HH.TT  (humidity int . temperature int)
//   mode 1 : distance cm (0~9999)
//   seg[6:0] = {g,f,e,d,c,b,a}, seg[7] = dp
//==============================================================================
module fnd_ctrl (
    input             clk,
    input             reset,
    input             mode,
    input      [7:0]  hum_int,
    input      [7:0]  tmp_int,
    input      [15:0] dist_cm,
    output reg [7:0]  seg,
    output reg [3:0]  an
);

    // digit values
    wire [13:0] d = (dist_cm > 16'd9999) ? 14'd9999 : dist_cm[13:0];
    wire [6:0]  h = (hum_int > 8'd99) ? 7'd99 : hum_int[6:0];
    wire [6:0]  t = (tmp_int > 8'd99) ? 7'd99 : tmp_int[6:0];

    reg [3:0] dig [0:3];   // dig[0] = rightmost
    always @(*) begin
        if (mode) begin
            dig[3] = d / 1000;
            dig[2] = (d / 100) % 10;
            dig[1] = (d / 10) % 10;
            dig[0] = d % 10;
        end else begin
            dig[3] = h / 10;
            dig[2] = h % 10;
            dig[1] = t / 10;
            dig[0] = t % 10;
        end
    end

    // ~1kHz scan per digit
    reg [16:0] cnt;
    always @(posedge clk or posedge reset) begin
        if (reset) cnt <= 0;
        else       cnt <= cnt + 1'b1;
    end
    wire [1:0] sel = cnt[16:15];

    function [6:0] dec7;      // returns {g,f,e,d,c,b,a}, active high
        input [3:0] v;
        case (v)
            4'd0: dec7 = 7'b0111111;
            4'd1: dec7 = 7'b0000110;
            4'd2: dec7 = 7'b1011011;
            4'd3: dec7 = 7'b1001111;
            4'd4: dec7 = 7'b1100110;
            4'd5: dec7 = 7'b1101101;
            4'd6: dec7 = 7'b1111101;
            4'd7: dec7 = 7'b0000111;
            4'd8: dec7 = 7'b1111111;
            4'd9: dec7 = 7'b1101111;
            default: dec7 = 7'b1000000;   // '-'
        endcase
    endfunction

    always @(*) begin
        an       = ~(4'b0001 << sel);
        seg[6:0] = ~dec7(dig[sel]);
        seg[7]   = ~((mode == 1'b0) && (sel == 2'd2));  // dp between HH.TT
    end

endmodule
