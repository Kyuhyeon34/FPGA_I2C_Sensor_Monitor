`timescale 1ns / 1ps

// Sixteen short add/shift steps, instead of a long combinational divider.
module binary_to_bcd16 (
    input clk, input reset, input start, input [15:0] binary,
    output reg [19:0] bcd, output reg done
);
    reg active;
    reg [3:0] bit_index;
    reg [15:0] shift_binary;
    reg [19:0] digits;
    reg [19:0] adjusted;
    integer d;
    always @* begin
        adjusted=digits;
        for(d=0;d<5;d=d+1)
            if(digits[d*4 +: 4]>=5) adjusted[d*4 +: 4]=digits[d*4 +: 4]+4'd3;
    end
    always @(posedge clk or posedge reset) begin
        if(reset) begin
            active<=0; bit_index<=0; shift_binary<=0; digits<=0; bcd<=0; done<=0;
        end else begin
            done<=0;
            if(start) begin
                active<=1; bit_index<=0; shift_binary<=binary; digits<=0;
            end else if(active) begin
                digits<={adjusted[18:0],shift_binary[15]};
                shift_binary<={shift_binary[14:0],1'b0};
                if(bit_index==15) begin
                    bcd<={adjusted[18:0],shift_binary[15]};
                    active<=0; done<=1;
                end else bit_index<=bit_index+1'b1;
            end
        end
    end
endmodule
