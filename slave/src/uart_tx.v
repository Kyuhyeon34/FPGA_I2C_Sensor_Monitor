`timescale 1ns / 1ps
//==============================================================================
// uart_tx : 8N1 transmitter
//==============================================================================
module uart_tx #(
    parameter CLK_HZ = 100_000_000,
    parameter BAUD   = 9600
)(
    input        clk,
    input        reset,
    input        start,
    input  [7:0] data,
    output reg   tx,
    output reg   busy
);
    localparam DIV = CLK_HZ / BAUD;

    reg [15:0] cnt;
    reg [3:0]  idx;      // 0:start, 1~8:data, 9:stop
    reg [9:0]  frame;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tx <= 1'b1; busy <= 1'b0; cnt <= 0; idx <= 0; frame <= 10'h3FF;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                frame <= {1'b1, data, 1'b0};
                busy  <= 1'b1;
                cnt   <= 0;
                idx   <= 0;
                tx    <= 1'b0;
            end
        end else begin
            if (cnt == DIV-1) begin
                cnt <= 0;
                if (idx == 9) begin
                    busy <= 1'b0;
                    tx   <= 1'b1;
                end else begin
                    idx <= idx + 1'b1;
                    tx  <= frame[idx+1];
                end
            end else cnt <= cnt + 1'b1;
        end
    end
endmodule

//==============================================================================
// uart_sensor_print : prints "H=45.0 T=23.1 D=0123\r\n" every PERIOD_CLK
//==============================================================================
module uart_sensor_print #(
    parameter CLK_HZ     = 100_000_000,
    parameter BAUD       = 9600,
    parameter PERIOD_CLK = 100_000_000     // 1 s
)(
    input         clk,
    input         reset,
    input  [7:0]  hum_int,
    input  [7:0]  hum_dec,
    input  [7:0]  tmp_int,
    input  [7:0]  tmp_dec,
    input  [15:0] dist_cm,
    output        tx
);
    localparam LEN = 22;

    reg  [26:0] pcnt;
    reg  [4:0]  ci;
    reg  [2:0]  st;
    reg         start;
    reg  [7:0]  ch;
    wire        busy;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .reset(reset), .start(start), .data(ch), .tx(tx), .busy(busy)
    );

    wire [6:0]  h  = (hum_int > 99) ? 7'd99 : hum_int[6:0];
    wire [6:0]  t  = (tmp_int > 99) ? 7'd99 : tmp_int[6:0];
    wire [3:0]  hd = (hum_dec > 9)  ? 4'd9  : hum_dec[3:0];
    wire [3:0]  td = (tmp_dec > 9)  ? 4'd9  : tmp_dec[3:0];
    wire [13:0] d  = (dist_cm > 9999) ? 14'd9999 : dist_cm[13:0];

    // distance -> BCD by sequential double dabble (14 clocks) : avoids a long
    // combinational divider path (/1000, /100, %10) that fails 100MHz timing
    reg  [13:0] dd_bin;
    reg  [15:0] dd_bcd;     // {thousands, hundreds, tens, ones}
    reg  [3:0]  dd_cnt;
    function [3:0] add3; input [3:0] v; add3 = (v >= 5) ? v + 4'd3 : v; endfunction
    wire [15:0] dd_adj = {add3(dd_bcd[15:12]), add3(dd_bcd[11:8]),
                          add3(dd_bcd[7:4]),   add3(dd_bcd[3:0])};

    // temperature / humidity digits latched once per print
    reg [3:0] h1, h0, t1, t0;

    function [7:0] asc; input [3:0] v; asc = 8'h30 + v; endfunction

    always @(*) begin
        case (ci)
            0:  ch = "H";  1: ch = "=";
            2:  ch = asc(h1);  3: ch = asc(h0);
            4:  ch = ".";  5: ch = asc(hd);
            6:  ch = " ";  7: ch = "T";  8: ch = "=";
            9:  ch = asc(t1); 10: ch = asc(t0);
            11: ch = "."; 12: ch = asc(td);
            13: ch = " "; 14: ch = "D"; 15: ch = "=";
            16: ch = asc(dd_bcd[15:12]);
            17: ch = asc(dd_bcd[11:8]);
            18: ch = asc(dd_bcd[7:4]);
            19: ch = asc(dd_bcd[3:0]);
            20: ch = 8'h0D; 21: ch = 8'h0A;
            default: ch = " ";
        endcase
    end

    localparam S_WAIT = 3'd0, S_SEND = 3'd1, S_B1 = 3'd2, S_B0 = 3'd3, S_CONV = 3'd4;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pcnt <= 0; ci <= 0; st <= S_WAIT; start <= 0;
            dd_bin <= 0; dd_bcd <= 0; dd_cnt <= 0;
            h1 <= 0; h0 <= 0; t1 <= 0; t0 <= 0;
        end else begin
            start <= 1'b0;
            case (st)
            S_WAIT: if (pcnt >= PERIOD_CLK-1) begin
                        pcnt   <= 0; ci <= 0;
                        dd_bin <= d; dd_bcd <= 0; dd_cnt <= 0;
                        h1 <= h / 10; h0 <= h % 10;
                        t1 <= t / 10; t0 <= t % 10;
                        st <= S_CONV;
                    end else pcnt <= pcnt + 1'b1;
            S_CONV: begin
                        dd_bcd <= {dd_adj[14:0], dd_bin[13]};
                        dd_bin <= {dd_bin[12:0], 1'b0};
                        dd_cnt <= dd_cnt + 1'b1;
                        if (dd_cnt == 13) st <= S_SEND;
                    end
            S_SEND: begin start <= 1'b1; st <= S_B1; end
            S_B1:   if (busy) st <= S_B0;
            S_B0:   if (!busy) begin
                        if (ci == LEN-1) st <= S_WAIT;
                        else begin ci <= ci + 1'b1; st <= S_SEND; end
                    end
            endcase
        end
    end
endmodule
