`timescale 1ns / 1ps

// 128x32 SSD1306 at 0x3C. Writes are arbitrated by top on the existing I2C bus.
// Each request sends control byte (00 command / 40 GDDRAM) + one data byte.
module ssd1306_oled #(
    parameter integer POWERUP_CYCLES = 10_000_000,
    parameter integer RETRY_CYCLES = 50_000_000,
    parameter integer ANIMATION_CYCLES = 50_000_000
)(
    input clk, input reset,
    input update, input [7:0] humidity, input [7:0] temperature,
    input [7:0] temperature_decimal,
    input humidity_valid, input [19:0] distance_bcd, input distance_valid,
    output request, output [7:0] control, output [7:0] data,
    input accepted, input transfer_done, input transfer_error,
    output reg ready, output reg error
);
    localparam [2:0] POWER=0, INIT=1, RANGE=2, DRAW=3, TURN_ON=4, IDLE=5, FAULT=6;
    localparam integer BASE_WAIT = (POWERUP_CYCLES > RETRY_CYCLES) ? POWERUP_CYCLES : RETRY_CYCLES;
    localparam integer MAX_WAIT = (BASE_WAIT > ANIMATION_CYCLES) ? BASE_WAIT : ANIMATION_CYCLES;
    localparam integer CW = (MAX_WAIT < 2) ? 1 : $clog2(MAX_WAIT);
    reg [2:0] state;
    reg [CW-1:0] count;
    reg [4:0] command_index;
    reg [2:0] range_index;
    reg [8:0] pixel_index;
    reg [1:0] animation_frame;
    reg partial_draw;
    reg waiting, pending, latest_valid, draw_valid;
    reg [7:0] latest_h, latest_t, draw_h, draw_t;
    reg [7:0] latest_t_decimal, draw_t_decimal;
    reg [19:0] latest_distance, draw_distance;
    reg latest_distance_valid, draw_distance_valid;
    wire [7:0] shown_h=(draw_h>99) ? 8'd99 : draw_h;
    wire [7:0] shown_t=(draw_t>99) ? 8'd99 : draw_t;
    // Saturate the OLED distance at 999 cm; retain the complete received value.
    wire [11:0] shown_distance=(draw_distance[19:12]!=0) ? 12'h999 : draw_distance[11:0];

    function [7:0] init_command;
        input [4:0] index;
        begin
            case (index)
                0: init_command=8'hae; // Display off while configuring/filling RAM.
                1: init_command=8'hd5;
                2: init_command=8'h80;
                3: init_command=8'ha8;
                4: init_command=8'h1f; // 32 multiplex rows.
                5: init_command=8'hd3;
                6: init_command=8'h00;
                7: init_command=8'h40;
                8: init_command=8'h8d;
                9: init_command=8'h14; // Internal charge pump.
                10: init_command=8'h20;
                11: init_command=8'h00; // Horizontal addressing.
                12: init_command=8'ha1;
                13: init_command=8'hc8;
                14: init_command=8'hda;
                15: init_command=8'h02; // Sequential COM configuration, 128x32.
                16: init_command=8'h81;
                17: init_command=8'h8f;
                18: init_command=8'hd9;
                19: init_command=8'hf1;
                20: init_command=8'hdb;
                21: init_command=8'h40;
                22: init_command=8'ha4;
                23: init_command=8'ha6;
                24: init_command=8'h2e; // Scrolling off.
                default: init_command=8'he3;
            endcase
        end
    endfunction
    function [7:0] range_command;
        input [2:0] index;
        begin
            case (index)
                0: range_command=8'h21;
                1: range_command=partial_draw ? 8'd96 : 8'd0;
                2: range_command=127;
                3: range_command=8'h22;
                4: range_command=0;
                default: range_command=3;
            endcase
        end
    endfunction
    function [7:0] text_character;
        input [1:0] line;
        input [3:0] index;
        begin
            if (line==0) begin
                case(index)
                    0: text_character="H";
                    1: text_character="U";
                    2: text_character="M";
                    3: text_character=":";
                    4: text_character=draw_valid ? 8'h30+shown_h/10 : "-";
                    5: text_character=draw_valid ? 8'h30+shown_h%10 : "-";
                    6: text_character="%";
                    default: text_character=" ";
                endcase
            end else if(line==1) begin
                case(index)
                    0: text_character="T";
                    1: text_character="E";
                    2: text_character="M";
                    3: text_character="P";
                    4: text_character=":";
                    5: text_character=draw_valid ? 8'h30+shown_t/10 : "-";
                    6: text_character=draw_valid ? 8'h30+shown_t%10 : "-";
                    7: text_character=".";
                    8: text_character=!draw_valid ? "-" :
                                      (draw_t_decimal<=9) ? 8'h30+draw_t_decimal : "?";
                    9: text_character="C";
                    default: text_character=" ";
                endcase
            end else begin
                case(index)
                    0: text_character="D";
                    1: text_character="I";
                    2: text_character="S";
                    3: text_character="T";
                    4: text_character=":";
                    5: text_character=!draw_distance_valid ? "-" :
                                      shown_distance[11:8]==0 ? " " : {4'h3,shown_distance[11:8]};
                    6: text_character=!draw_distance_valid ? "-" :
                                      shown_distance[11:4]==0 ? " " : {4'h3,shown_distance[7:4]};
                    7: text_character=draw_distance_valid ? {4'h3,shown_distance[3:0]} : "-";
                    8: text_character="c";
                    9: text_character="m";
                    default: text_character=" ";
                endcase
            end
        end
    endfunction
    function [7:0] glyph_column;
        input [7:0] character;
        input [2:0] column;
        reg [39:0] columns;
        begin
            case(character)
                "H": columns=40'h7f0808087f;
                "U": columns=40'h3f4040403f;
                "M": columns=40'h7f020c027f;
                "T": columns=40'h01017f0101;
                "E": columns=40'h414949497f;
                "P": columns=40'h060909097f;
                "C": columns=40'h224141413e;
                "D": columns=40'h3e4141417f;
                "I": columns=40'h00417f4100;
                "S": columns=40'h3149494946;
                "c": columns=40'h2844444438;
                "m": columns=40'h780418047c;
                ":": columns=40'h0000363600;
                ".": columns=40'h0000606000;
                "?": columns=40'h0609510102;
                "%": columns=40'h6364081363;
                "-": columns=40'h0808080808;
                "0": columns=40'h3e4549513e;
                "1": columns=40'h00407f4200;
                "2": columns=40'h4649516142;
                "3": columns=40'h314b454121;
                "4": columns=40'h107f121418;
                "5": columns=40'h3945454527;
                "6": columns=40'h3049494a3c;
                "7": columns=40'h0305097101;
                "8": columns=40'h3649494936;
                "9": columns=40'h1e29494906;
                default: columns=0;
            endcase
            glyph_column=(column<5) ? columns[column*8 +: 8] : 8'h00;
        end
    endfunction
    // BEGIN GENERATED SLOWPOKE ROM: tests/compile_slowpoke.ps1
    function [7:0] slowpoke_byte;
        input [8:0] address;
        begin
            case(address)
                9'd0: slowpoke_byte=8'h00;
                9'd1: slowpoke_byte=8'h00;
                9'd2: slowpoke_byte=8'h80;
                9'd3: slowpoke_byte=8'hc0;
                9'd4: slowpoke_byte=8'h60;
                9'd5: slowpoke_byte=8'hb0;
                9'd6: slowpoke_byte=8'hb0;
                9'd7: slowpoke_byte=8'hf0;
                9'd8: slowpoke_byte=8'h70;
                9'd9: slowpoke_byte=8'he0;
                9'd10: slowpoke_byte=8'hc0;
                9'd11: slowpoke_byte=8'h80;
                9'd12: slowpoke_byte=8'h80;
                9'd13: slowpoke_byte=8'hc0;
                9'd14: slowpoke_byte=8'hc0;
                9'd15: slowpoke_byte=8'hc0;
                9'd16: slowpoke_byte=8'hc0;
                9'd17: slowpoke_byte=8'hc0;
                9'd18: slowpoke_byte=8'hc0;
                9'd19: slowpoke_byte=8'h80;
                9'd20: slowpoke_byte=8'h80;
                9'd21: slowpoke_byte=8'hc0;
                9'd22: slowpoke_byte=8'he0;
                9'd23: slowpoke_byte=8'h70;
                9'd24: slowpoke_byte=8'hf0;
                9'd25: slowpoke_byte=8'hb0;
                9'd26: slowpoke_byte=8'hb0;
                9'd27: slowpoke_byte=8'h60;
                9'd28: slowpoke_byte=8'hc0;
                9'd29: slowpoke_byte=8'h80;
                9'd30: slowpoke_byte=8'h00;
                9'd31: slowpoke_byte=8'h00;
                9'd32: slowpoke_byte=8'h00;
                9'd33: slowpoke_byte=8'h00;
                9'd34: slowpoke_byte=8'h01;
                9'd35: slowpoke_byte=8'h03;
                9'd36: slowpoke_byte=8'hc7;
                9'd37: slowpoke_byte=8'hf3;
                9'd38: slowpoke_byte=8'h1d;
                9'd39: slowpoke_byte=8'hff;
                9'd40: slowpoke_byte=8'hf6;
                9'd41: slowpoke_byte=8'hff;
                9'd42: slowpoke_byte=8'hff;
                9'd43: slowpoke_byte=8'hf7;
                9'd44: slowpoke_byte=8'h7f;
                9'd45: slowpoke_byte=8'h7f;
                9'd46: slowpoke_byte=8'hff;
                9'd47: slowpoke_byte=8'hff;
                9'd48: slowpoke_byte=8'hff;
                9'd49: slowpoke_byte=8'hff;
                9'd50: slowpoke_byte=8'h7f;
                9'd51: slowpoke_byte=8'h0f;
                9'd52: slowpoke_byte=8'hf7;
                9'd53: slowpoke_byte=8'hff;
                9'd54: slowpoke_byte=8'hff;
                9'd55: slowpoke_byte=8'hf6;
                9'd56: slowpoke_byte=8'hff;
                9'd57: slowpoke_byte=8'h1d;
                9'd58: slowpoke_byte=8'hf3;
                9'd59: slowpoke_byte=8'hc6;
                9'd60: slowpoke_byte=8'h03;
                9'd61: slowpoke_byte=8'h01;
                9'd62: slowpoke_byte=8'h00;
                9'd63: slowpoke_byte=8'h00;
                9'd64: slowpoke_byte=8'h00;
                9'd65: slowpoke_byte=8'h00;
                9'd66: slowpoke_byte=8'h00;
                9'd67: slowpoke_byte=8'h1e;
                9'd68: slowpoke_byte=8'h8f;
                9'd69: slowpoke_byte=8'hff;
                9'd70: slowpoke_byte=8'hfb;
                9'd71: slowpoke_byte=8'h9d;
                9'd72: slowpoke_byte=8'h1d;
                9'd73: slowpoke_byte=8'h3f;
                9'd74: slowpoke_byte=8'h7e;
                9'd75: slowpoke_byte=8'h3f;
                9'd76: slowpoke_byte=8'h1f;
                9'd77: slowpoke_byte=8'h1b;
                9'd78: slowpoke_byte=8'h1f;
                9'd79: slowpoke_byte=8'h1f;
                9'd80: slowpoke_byte=8'h1f;
                9'd81: slowpoke_byte=8'h1f;
                9'd82: slowpoke_byte=8'h1b;
                9'd83: slowpoke_byte=8'h1f;
                9'd84: slowpoke_byte=8'h3f;
                9'd85: slowpoke_byte=8'h7e;
                9'd86: slowpoke_byte=8'h3f;
                9'd87: slowpoke_byte=8'h1d;
                9'd88: slowpoke_byte=8'h9d;
                9'd89: slowpoke_byte=8'hfb;
                9'd90: slowpoke_byte=8'hff;
                9'd91: slowpoke_byte=8'h8f;
                9'd92: slowpoke_byte=8'h1e;
                9'd93: slowpoke_byte=8'h00;
                9'd94: slowpoke_byte=8'h00;
                9'd95: slowpoke_byte=8'h00;
                9'd96: slowpoke_byte=8'h00;
                9'd97: slowpoke_byte=8'h00;
                9'd98: slowpoke_byte=8'h00;
                9'd99: slowpoke_byte=8'h00;
                9'd100: slowpoke_byte=8'h00;
                9'd101: slowpoke_byte=8'h00;
                9'd102: slowpoke_byte=8'h03;
                9'd103: slowpoke_byte=8'h03;
                9'd104: slowpoke_byte=8'h07;
                9'd105: slowpoke_byte=8'h04;
                9'd106: slowpoke_byte=8'h0c;
                9'd107: slowpoke_byte=8'h1a;
                9'd108: slowpoke_byte=8'h13;
                9'd109: slowpoke_byte=8'h17;
                9'd110: slowpoke_byte=8'h17;
                9'd111: slowpoke_byte=8'h17;
                9'd112: slowpoke_byte=8'h17;
                9'd113: slowpoke_byte=8'h17;
                9'd114: slowpoke_byte=8'h17;
                9'd115: slowpoke_byte=8'h17;
                9'd116: slowpoke_byte=8'h1a;
                9'd117: slowpoke_byte=8'h0c;
                9'd118: slowpoke_byte=8'h04;
                9'd119: slowpoke_byte=8'h07;
                9'd120: slowpoke_byte=8'h03;
                9'd121: slowpoke_byte=8'h03;
                9'd122: slowpoke_byte=8'h00;
                9'd123: slowpoke_byte=8'h00;
                9'd124: slowpoke_byte=8'h00;
                9'd125: slowpoke_byte=8'h00;
                9'd126: slowpoke_byte=8'h00;
                9'd127: slowpoke_byte=8'h00;
                9'd128: slowpoke_byte=8'h00;
                9'd129: slowpoke_byte=8'h00;
                9'd130: slowpoke_byte=8'h00;
                9'd131: slowpoke_byte=8'h80;
                9'd132: slowpoke_byte=8'hc0;
                9'd133: slowpoke_byte=8'h60;
                9'd134: slowpoke_byte=8'h60;
                9'd135: slowpoke_byte=8'he0;
                9'd136: slowpoke_byte=8'he0;
                9'd137: slowpoke_byte=8'hc0;
                9'd138: slowpoke_byte=8'h80;
                9'd139: slowpoke_byte=8'h00;
                9'd140: slowpoke_byte=8'h00;
                9'd141: slowpoke_byte=8'h80;
                9'd142: slowpoke_byte=8'h80;
                9'd143: slowpoke_byte=8'h80;
                9'd144: slowpoke_byte=8'h80;
                9'd145: slowpoke_byte=8'h80;
                9'd146: slowpoke_byte=8'h80;
                9'd147: slowpoke_byte=8'h00;
                9'd148: slowpoke_byte=8'h00;
                9'd149: slowpoke_byte=8'h80;
                9'd150: slowpoke_byte=8'hc0;
                9'd151: slowpoke_byte=8'he0;
                9'd152: slowpoke_byte=8'he0;
                9'd153: slowpoke_byte=8'h60;
                9'd154: slowpoke_byte=8'h60;
                9'd155: slowpoke_byte=8'hc0;
                9'd156: slowpoke_byte=8'h80;
                9'd157: slowpoke_byte=8'h00;
                9'd158: slowpoke_byte=8'h00;
                9'd159: slowpoke_byte=8'h00;
                9'd160: slowpoke_byte=8'h00;
                9'd161: slowpoke_byte=8'h00;
                9'd162: slowpoke_byte=8'h03;
                9'd163: slowpoke_byte=8'h07;
                9'd164: slowpoke_byte=8'h8e;
                9'd165: slowpoke_byte=8'he7;
                9'd166: slowpoke_byte=8'h3b;
                9'd167: slowpoke_byte=8'hff;
                9'd168: slowpoke_byte=8'hec;
                9'd169: slowpoke_byte=8'hff;
                9'd170: slowpoke_byte=8'hff;
                9'd171: slowpoke_byte=8'hef;
                9'd172: slowpoke_byte=8'hff;
                9'd173: slowpoke_byte=8'hff;
                9'd174: slowpoke_byte=8'hff;
                9'd175: slowpoke_byte=8'hff;
                9'd176: slowpoke_byte=8'hff;
                9'd177: slowpoke_byte=8'hff;
                9'd178: slowpoke_byte=8'hff;
                9'd179: slowpoke_byte=8'h1f;
                9'd180: slowpoke_byte=8'hef;
                9'd181: slowpoke_byte=8'hff;
                9'd182: slowpoke_byte=8'hff;
                9'd183: slowpoke_byte=8'hec;
                9'd184: slowpoke_byte=8'hff;
                9'd185: slowpoke_byte=8'h3b;
                9'd186: slowpoke_byte=8'he7;
                9'd187: slowpoke_byte=8'h8c;
                9'd188: slowpoke_byte=8'h07;
                9'd189: slowpoke_byte=8'h03;
                9'd190: slowpoke_byte=8'h00;
                9'd191: slowpoke_byte=8'h00;
                9'd192: slowpoke_byte=8'h00;
                9'd193: slowpoke_byte=8'h00;
                9'd194: slowpoke_byte=8'h00;
                9'd195: slowpoke_byte=8'h3c;
                9'd196: slowpoke_byte=8'h1f;
                9'd197: slowpoke_byte=8'hff;
                9'd198: slowpoke_byte=8'hf6;
                9'd199: slowpoke_byte=8'h3b;
                9'd200: slowpoke_byte=8'h3b;
                9'd201: slowpoke_byte=8'h7f;
                9'd202: slowpoke_byte=8'hfd;
                9'd203: slowpoke_byte=8'h7f;
                9'd204: slowpoke_byte=8'h3e;
                9'd205: slowpoke_byte=8'h36;
                9'd206: slowpoke_byte=8'h3f;
                9'd207: slowpoke_byte=8'h3f;
                9'd208: slowpoke_byte=8'h3f;
                9'd209: slowpoke_byte=8'h3f;
                9'd210: slowpoke_byte=8'h36;
                9'd211: slowpoke_byte=8'h3e;
                9'd212: slowpoke_byte=8'h7f;
                9'd213: slowpoke_byte=8'hfd;
                9'd214: slowpoke_byte=8'h7f;
                9'd215: slowpoke_byte=8'h3b;
                9'd216: slowpoke_byte=8'h3b;
                9'd217: slowpoke_byte=8'hf6;
                9'd218: slowpoke_byte=8'hff;
                9'd219: slowpoke_byte=8'h1f;
                9'd220: slowpoke_byte=8'h3c;
                9'd221: slowpoke_byte=8'h00;
                9'd222: slowpoke_byte=8'h00;
                9'd223: slowpoke_byte=8'h00;
                9'd224: slowpoke_byte=8'h00;
                9'd225: slowpoke_byte=8'h00;
                9'd226: slowpoke_byte=8'h00;
                9'd227: slowpoke_byte=8'h00;
                9'd228: slowpoke_byte=8'h01;
                9'd229: slowpoke_byte=8'h01;
                9'd230: slowpoke_byte=8'h07;
                9'd231: slowpoke_byte=8'h07;
                9'd232: slowpoke_byte=8'h0e;
                9'd233: slowpoke_byte=8'h08;
                9'd234: slowpoke_byte=8'h18;
                9'd235: slowpoke_byte=8'h34;
                9'd236: slowpoke_byte=8'h26;
                9'd237: slowpoke_byte=8'h2e;
                9'd238: slowpoke_byte=8'h2e;
                9'd239: slowpoke_byte=8'h2e;
                9'd240: slowpoke_byte=8'h2e;
                9'd241: slowpoke_byte=8'h2e;
                9'd242: slowpoke_byte=8'h2e;
                9'd243: slowpoke_byte=8'h2e;
                9'd244: slowpoke_byte=8'h34;
                9'd245: slowpoke_byte=8'h18;
                9'd246: slowpoke_byte=8'h08;
                9'd247: slowpoke_byte=8'h0e;
                9'd248: slowpoke_byte=8'h07;
                9'd249: slowpoke_byte=8'h07;
                9'd250: slowpoke_byte=8'h01;
                9'd251: slowpoke_byte=8'h01;
                9'd252: slowpoke_byte=8'h00;
                9'd253: slowpoke_byte=8'h00;
                9'd254: slowpoke_byte=8'h00;
                9'd255: slowpoke_byte=8'h00;
                9'd256: slowpoke_byte=8'h00;
                9'd257: slowpoke_byte=8'h00;
                9'd258: slowpoke_byte=8'h00;
                9'd259: slowpoke_byte=8'h80;
                9'd260: slowpoke_byte=8'hc0;
                9'd261: slowpoke_byte=8'h60;
                9'd262: slowpoke_byte=8'h60;
                9'd263: slowpoke_byte=8'he0;
                9'd264: slowpoke_byte=8'he0;
                9'd265: slowpoke_byte=8'hc0;
                9'd266: slowpoke_byte=8'h80;
                9'd267: slowpoke_byte=8'h00;
                9'd268: slowpoke_byte=8'h00;
                9'd269: slowpoke_byte=8'h80;
                9'd270: slowpoke_byte=8'h80;
                9'd271: slowpoke_byte=8'h80;
                9'd272: slowpoke_byte=8'h80;
                9'd273: slowpoke_byte=8'h80;
                9'd274: slowpoke_byte=8'h80;
                9'd275: slowpoke_byte=8'h00;
                9'd276: slowpoke_byte=8'h00;
                9'd277: slowpoke_byte=8'h80;
                9'd278: slowpoke_byte=8'hc0;
                9'd279: slowpoke_byte=8'he0;
                9'd280: slowpoke_byte=8'he0;
                9'd281: slowpoke_byte=8'h60;
                9'd282: slowpoke_byte=8'h60;
                9'd283: slowpoke_byte=8'hc0;
                9'd284: slowpoke_byte=8'h80;
                9'd285: slowpoke_byte=8'h00;
                9'd286: slowpoke_byte=8'h00;
                9'd287: slowpoke_byte=8'h00;
                9'd288: slowpoke_byte=8'h00;
                9'd289: slowpoke_byte=8'h00;
                9'd290: slowpoke_byte=8'h03;
                9'd291: slowpoke_byte=8'h07;
                9'd292: slowpoke_byte=8'h8e;
                9'd293: slowpoke_byte=8'he7;
                9'd294: slowpoke_byte=8'h3b;
                9'd295: slowpoke_byte=8'hff;
                9'd296: slowpoke_byte=8'h6c;
                9'd297: slowpoke_byte=8'hff;
                9'd298: slowpoke_byte=8'hff;
                9'd299: slowpoke_byte=8'h6f;
                9'd300: slowpoke_byte=8'h7f;
                9'd301: slowpoke_byte=8'hff;
                9'd302: slowpoke_byte=8'hff;
                9'd303: slowpoke_byte=8'hff;
                9'd304: slowpoke_byte=8'hff;
                9'd305: slowpoke_byte=8'hff;
                9'd306: slowpoke_byte=8'hff;
                9'd307: slowpoke_byte=8'h1f;
                9'd308: slowpoke_byte=8'h6f;
                9'd309: slowpoke_byte=8'hff;
                9'd310: slowpoke_byte=8'hff;
                9'd311: slowpoke_byte=8'h6c;
                9'd312: slowpoke_byte=8'hff;
                9'd313: slowpoke_byte=8'h3b;
                9'd314: slowpoke_byte=8'he7;
                9'd315: slowpoke_byte=8'h8c;
                9'd316: slowpoke_byte=8'h07;
                9'd317: slowpoke_byte=8'h03;
                9'd318: slowpoke_byte=8'h00;
                9'd319: slowpoke_byte=8'h00;
                9'd320: slowpoke_byte=8'h00;
                9'd321: slowpoke_byte=8'h00;
                9'd322: slowpoke_byte=8'h00;
                9'd323: slowpoke_byte=8'h3c;
                9'd324: slowpoke_byte=8'h1f;
                9'd325: slowpoke_byte=8'hff;
                9'd326: slowpoke_byte=8'hf6;
                9'd327: slowpoke_byte=8'h3b;
                9'd328: slowpoke_byte=8'h3b;
                9'd329: slowpoke_byte=8'h7f;
                9'd330: slowpoke_byte=8'hfd;
                9'd331: slowpoke_byte=8'h7f;
                9'd332: slowpoke_byte=8'h3e;
                9'd333: slowpoke_byte=8'h36;
                9'd334: slowpoke_byte=8'h3f;
                9'd335: slowpoke_byte=8'h3f;
                9'd336: slowpoke_byte=8'h3f;
                9'd337: slowpoke_byte=8'h3f;
                9'd338: slowpoke_byte=8'h36;
                9'd339: slowpoke_byte=8'h3e;
                9'd340: slowpoke_byte=8'h7f;
                9'd341: slowpoke_byte=8'hfd;
                9'd342: slowpoke_byte=8'h7f;
                9'd343: slowpoke_byte=8'h3b;
                9'd344: slowpoke_byte=8'h3b;
                9'd345: slowpoke_byte=8'hf6;
                9'd346: slowpoke_byte=8'hff;
                9'd347: slowpoke_byte=8'h1f;
                9'd348: slowpoke_byte=8'h3c;
                9'd349: slowpoke_byte=8'h00;
                9'd350: slowpoke_byte=8'h00;
                9'd351: slowpoke_byte=8'h00;
                9'd352: slowpoke_byte=8'h00;
                9'd353: slowpoke_byte=8'h00;
                9'd354: slowpoke_byte=8'h00;
                9'd355: slowpoke_byte=8'h00;
                9'd356: slowpoke_byte=8'h01;
                9'd357: slowpoke_byte=8'h01;
                9'd358: slowpoke_byte=8'h07;
                9'd359: slowpoke_byte=8'h07;
                9'd360: slowpoke_byte=8'h0e;
                9'd361: slowpoke_byte=8'h08;
                9'd362: slowpoke_byte=8'h18;
                9'd363: slowpoke_byte=8'h34;
                9'd364: slowpoke_byte=8'h26;
                9'd365: slowpoke_byte=8'h2e;
                9'd366: slowpoke_byte=8'h2e;
                9'd367: slowpoke_byte=8'h2e;
                9'd368: slowpoke_byte=8'h2e;
                9'd369: slowpoke_byte=8'h2e;
                9'd370: slowpoke_byte=8'h2e;
                9'd371: slowpoke_byte=8'h2e;
                9'd372: slowpoke_byte=8'h34;
                9'd373: slowpoke_byte=8'h18;
                9'd374: slowpoke_byte=8'h08;
                9'd375: slowpoke_byte=8'h0e;
                9'd376: slowpoke_byte=8'h07;
                9'd377: slowpoke_byte=8'h07;
                9'd378: slowpoke_byte=8'h01;
                9'd379: slowpoke_byte=8'h01;
                9'd380: slowpoke_byte=8'h00;
                9'd381: slowpoke_byte=8'h00;
                9'd382: slowpoke_byte=8'h00;
                9'd383: slowpoke_byte=8'h00;
                9'd384: slowpoke_byte=8'h00;
                9'd385: slowpoke_byte=8'h00;
                9'd386: slowpoke_byte=8'h80;
                9'd387: slowpoke_byte=8'hc0;
                9'd388: slowpoke_byte=8'h60;
                9'd389: slowpoke_byte=8'hb0;
                9'd390: slowpoke_byte=8'hb0;
                9'd391: slowpoke_byte=8'hf0;
                9'd392: slowpoke_byte=8'h70;
                9'd393: slowpoke_byte=8'he0;
                9'd394: slowpoke_byte=8'hc0;
                9'd395: slowpoke_byte=8'h80;
                9'd396: slowpoke_byte=8'h80;
                9'd397: slowpoke_byte=8'hc0;
                9'd398: slowpoke_byte=8'hc0;
                9'd399: slowpoke_byte=8'hc0;
                9'd400: slowpoke_byte=8'hc0;
                9'd401: slowpoke_byte=8'hc0;
                9'd402: slowpoke_byte=8'hc0;
                9'd403: slowpoke_byte=8'h80;
                9'd404: slowpoke_byte=8'h80;
                9'd405: slowpoke_byte=8'hc0;
                9'd406: slowpoke_byte=8'he0;
                9'd407: slowpoke_byte=8'h70;
                9'd408: slowpoke_byte=8'hf0;
                9'd409: slowpoke_byte=8'hb0;
                9'd410: slowpoke_byte=8'hb0;
                9'd411: slowpoke_byte=8'h60;
                9'd412: slowpoke_byte=8'hc0;
                9'd413: slowpoke_byte=8'h80;
                9'd414: slowpoke_byte=8'h00;
                9'd415: slowpoke_byte=8'h00;
                9'd416: slowpoke_byte=8'h00;
                9'd417: slowpoke_byte=8'h00;
                9'd418: slowpoke_byte=8'h01;
                9'd419: slowpoke_byte=8'h03;
                9'd420: slowpoke_byte=8'hc7;
                9'd421: slowpoke_byte=8'hf3;
                9'd422: slowpoke_byte=8'h1d;
                9'd423: slowpoke_byte=8'hff;
                9'd424: slowpoke_byte=8'hf6;
                9'd425: slowpoke_byte=8'hff;
                9'd426: slowpoke_byte=8'hff;
                9'd427: slowpoke_byte=8'hf7;
                9'd428: slowpoke_byte=8'h7f;
                9'd429: slowpoke_byte=8'h7f;
                9'd430: slowpoke_byte=8'hff;
                9'd431: slowpoke_byte=8'hff;
                9'd432: slowpoke_byte=8'hff;
                9'd433: slowpoke_byte=8'hff;
                9'd434: slowpoke_byte=8'h7f;
                9'd435: slowpoke_byte=8'h0f;
                9'd436: slowpoke_byte=8'hf7;
                9'd437: slowpoke_byte=8'hff;
                9'd438: slowpoke_byte=8'hff;
                9'd439: slowpoke_byte=8'hf6;
                9'd440: slowpoke_byte=8'hff;
                9'd441: slowpoke_byte=8'h1d;
                9'd442: slowpoke_byte=8'hf3;
                9'd443: slowpoke_byte=8'hc6;
                9'd444: slowpoke_byte=8'h03;
                9'd445: slowpoke_byte=8'h01;
                9'd446: slowpoke_byte=8'h00;
                9'd447: slowpoke_byte=8'h00;
                9'd448: slowpoke_byte=8'h00;
                9'd449: slowpoke_byte=8'h00;
                9'd450: slowpoke_byte=8'h00;
                9'd451: slowpoke_byte=8'h1e;
                9'd452: slowpoke_byte=8'h8f;
                9'd453: slowpoke_byte=8'hff;
                9'd454: slowpoke_byte=8'hfb;
                9'd455: slowpoke_byte=8'h9d;
                9'd456: slowpoke_byte=8'h1d;
                9'd457: slowpoke_byte=8'h3f;
                9'd458: slowpoke_byte=8'h7e;
                9'd459: slowpoke_byte=8'h3f;
                9'd460: slowpoke_byte=8'h1f;
                9'd461: slowpoke_byte=8'h1b;
                9'd462: slowpoke_byte=8'h1f;
                9'd463: slowpoke_byte=8'h1f;
                9'd464: slowpoke_byte=8'h1f;
                9'd465: slowpoke_byte=8'h1f;
                9'd466: slowpoke_byte=8'h1b;
                9'd467: slowpoke_byte=8'h1f;
                9'd468: slowpoke_byte=8'h3f;
                9'd469: slowpoke_byte=8'h7e;
                9'd470: slowpoke_byte=8'h3f;
                9'd471: slowpoke_byte=8'h1d;
                9'd472: slowpoke_byte=8'h9d;
                9'd473: slowpoke_byte=8'hfb;
                9'd474: slowpoke_byte=8'hff;
                9'd475: slowpoke_byte=8'h8f;
                9'd476: slowpoke_byte=8'h1e;
                9'd477: slowpoke_byte=8'h00;
                9'd478: slowpoke_byte=8'h00;
                9'd479: slowpoke_byte=8'h00;
                9'd480: slowpoke_byte=8'h00;
                9'd481: slowpoke_byte=8'h00;
                9'd482: slowpoke_byte=8'h00;
                9'd483: slowpoke_byte=8'h00;
                9'd484: slowpoke_byte=8'h00;
                9'd485: slowpoke_byte=8'h00;
                9'd486: slowpoke_byte=8'h03;
                9'd487: slowpoke_byte=8'h03;
                9'd488: slowpoke_byte=8'h07;
                9'd489: slowpoke_byte=8'h04;
                9'd490: slowpoke_byte=8'h0c;
                9'd491: slowpoke_byte=8'h1a;
                9'd492: slowpoke_byte=8'h13;
                9'd493: slowpoke_byte=8'h17;
                9'd494: slowpoke_byte=8'h17;
                9'd495: slowpoke_byte=8'h17;
                9'd496: slowpoke_byte=8'h17;
                9'd497: slowpoke_byte=8'h17;
                9'd498: slowpoke_byte=8'h17;
                9'd499: slowpoke_byte=8'h17;
                9'd500: slowpoke_byte=8'h1a;
                9'd501: slowpoke_byte=8'h0c;
                9'd502: slowpoke_byte=8'h04;
                9'd503: slowpoke_byte=8'h07;
                9'd504: slowpoke_byte=8'h03;
                9'd505: slowpoke_byte=8'h03;
                9'd506: slowpoke_byte=8'h00;
                9'd507: slowpoke_byte=8'h00;
                9'd508: slowpoke_byte=8'h00;
                9'd509: slowpoke_byte=8'h00;
                9'd510: slowpoke_byte=8'h00;
                9'd511: slowpoke_byte=8'h00;
                default: slowpoke_byte=8'h00;
            endcase
        end
    endfunction
    // END GENERATED SLOWPOKE ROM
    function [7:0] screen_byte;
        input [8:0] position;
        reg [7:0] character, column;
        reg [7:0] pixels;
        integer bit_number, y, line, row;
        begin
            // Three 6x8 text rows at y=0,12,24; the right 32x32 stays animated.
            pixels=0;
            for(bit_number=0;bit_number<8;bit_number=bit_number+1) begin
                y=position[8:7]*8+bit_number;
                line=(y<12) ? 0 : ((y<24) ? 1 : 2);
                row=(y<12) ? y : ((y<24) ? y-12 : y-24);
                character=text_character(line, position[6:0]/6);
                column=glyph_column(character, position[6:0]%6);
                if(row<7) pixels[bit_number]=column[row];
            end
            if(position[6:0]>=96)
                screen_byte=slowpoke_byte({animation_frame,position[8:7],position[4:0]});
            else screen_byte=pixels;
        end
    endfunction

    assign request=!waiting && (state==INIT || state==RANGE || state==DRAW || state==TURN_ON);
    assign control=(state==DRAW) ? 8'h40 : 8'h00;
    assign data=(state==INIT) ? init_command(command_index) :
                (state==RANGE) ? range_command(range_index) :
                (state==DRAW) ? screen_byte(pixel_index) : 8'haf;

    always @(posedge clk or posedge reset) begin
        if(reset) begin
            state<=POWER; count<=0; command_index<=0; range_index<=0; pixel_index<=0;
            animation_frame<=0; partial_draw<=0;
            waiting<=0; pending<=0; latest_valid<=0; draw_valid<=0;
            latest_h<=0; latest_t<=0; draw_h<=0; draw_t<=0;
            latest_t_decimal<=0; draw_t_decimal<=0;
            latest_distance<=0; draw_distance<=0;
            latest_distance_valid<=0; draw_distance_valid<=0;
            ready<=0; error<=0;
        end else begin
            if(request && accepted) waiting<=1;
            case(state)
                POWER: begin
                    if(count==POWERUP_CYCLES-1) begin state<=INIT; count<=0; end
                    else count<=count+1'b1;
                end
                FAULT: begin
                    // Retry an absent/hot-plugged OLED without blocking sensors.
                    if(count==RETRY_CYCLES-1) begin
                        state<=INIT; command_index<=0; count<=0;
                    end else count<=count+1'b1;
                end
                IDLE: if(pending) begin
                    draw_h<=latest_h; draw_t<=latest_t; draw_valid<=latest_valid;
                    draw_t_decimal<=latest_t_decimal;
                    draw_distance<=latest_distance; draw_distance_valid<=latest_distance_valid;
                    pending<=0; range_index<=0; state<=RANGE; partial_draw<=0; count<=0;
                end else if(count==ANIMATION_CYCLES-1) begin
                    animation_frame<=animation_frame+1'b1;
                    partial_draw<=1; range_index<=0; state<=RANGE; count<=0;
                end else count<=count+1'b1;
                default: begin
                    if(waiting && transfer_done) begin
                        waiting<=0;
                        if(transfer_error) begin
                            state<=FAULT; count<=0; error<=1; ready<=0;
                        end else case(state)
                            INIT: begin
                                if(command_index==24) begin
                                    draw_h<=latest_h; draw_t<=latest_t; draw_valid<=latest_valid;
                                    draw_t_decimal<=latest_t_decimal;
                                    draw_distance<=latest_distance; draw_distance_valid<=latest_distance_valid;
                                    pending<=0; range_index<=0; state<=RANGE;
                                    animation_frame<=0; partial_draw<=0; count<=0;
                                end else command_index<=command_index+1'b1;
                            end
                            RANGE: begin
                                if(range_index==5) begin
                                    pixel_index<=partial_draw ? 9'd96 : 9'd0; state<=DRAW;
                                end
                                else range_index<=range_index+1'b1;
                            end
                            DRAW: begin
                                if(pixel_index==511) state<=ready ? IDLE : TURN_ON;
                                else if(partial_draw && pixel_index[6:0]==127)
                                    pixel_index<=pixel_index+9'd97;
                                else pixel_index<=pixel_index+1'b1;
                            end
                            TURN_ON: begin ready<=1; error<=0; state<=IDLE; end
                            default: state<=POWER;
                        endcase
                    end
                end
            endcase
            // Last assignment wins: do not lose an update arriving at frame end.
            if(update) begin
                if(humidity_valid) begin
                    latest_h<=humidity; latest_t<=temperature; latest_valid<=1;
                    latest_t_decimal<=temperature_decimal;
                end
                if(distance_valid) begin
                    latest_distance<=distance_bcd; latest_distance_valid<=1;
                end
                pending<=1;
            end
        end
    end
endmodule
