`timescale 1ns / 1ps
//==============================================================================
// dht11_ctrl : DHT11 single-wire temperature / humidity reader
//   - measures every PERIOD_US (DHT11 needs >= 1s between reads)
//   - open-drain style : drive 0 or release (Z), external/xdc PULLUP required
//==============================================================================
module dht11_ctrl #(
    parameter CLK_PER_US = 100,          // 100MHz
    parameter PERIOD_US  = 1_000_000,    // 1 s
    parameter START_US   = 20_000        // host start low : >= 18 ms
)(
    input            clk,
    input            reset,
    inout            dht11_data,

    output reg [7:0] hum_int,
    output reg [7:0] hum_dec,
    output reg [7:0] tmp_int,
    output reg [7:0] tmp_dec,
    output reg       valid,          // last read checksum OK
    output reg       done_toggle     // toggles at every finished read (OK or error)
);

    // tri-state (PPT : io_mode 1 = input -> Z)
    reg  io_mode;                        // 1: input(release), 0: output
    wire o_data = 1'b0;                  // host only ever drives low
    assign dht11_data = io_mode ? 1'bz : o_data;

    reg [1:0] din_sync;
    always @(posedge clk) din_sync <= {din_sync[0], dht11_data};
    wire din = din_sync[1];

    // 1us tick
    reg [7:0] div;
    wire tick_us = (div == CLK_PER_US-1);
    always @(posedge clk or posedge reset) begin
        if (reset)        div <= 0;
        else if (tick_us) div <= 0;
        else              div <= div + 1'b1;
    end

    localparam S_WAIT      = 3'd0,
               S_START     = 3'd1,
               S_REL       = 3'd2,   // wait sensor pulls low
               S_RESP_LOW  = 3'd3,   // ~80us low
               S_RESP_HIGH = 3'd4,   // ~80us high
               S_BIT_LOW   = 3'd5,   // ~50us low
               S_BIT_HIGH  = 3'd6,   // 26~28us -> 0, 70us -> 1
               S_DONE      = 3'd7;

    localparam TIMEOUT_US = 200;
    localparam BIT1_TH_US = 45;

    reg [2:0]  state;
    reg [19:0] us_cnt;
    reg [5:0]  bit_cnt;
    reg [39:0] data;

    wire [7:0] chk = data[39:32] + data[31:24] + data[23:16] + data[15:8];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= S_WAIT; us_cnt <= 0; bit_cnt <= 0; data <= 0;
            io_mode <= 1'b1;
            hum_int <= 0; hum_dec <= 0; tmp_int <= 0; tmp_dec <= 0;
            valid <= 0; done_toggle <= 0;
        end else begin
            case (state)
            S_WAIT: begin
                io_mode <= 1'b1;
                if (tick_us) begin
                    if (us_cnt >= PERIOD_US-1) begin us_cnt <= 0; state <= S_START; end
                    else us_cnt <= us_cnt + 1'b1;
                end
            end

            S_START: begin
                io_mode <= 1'b0;                     // drive low
                if (tick_us) begin
                    if (us_cnt >= START_US-1) begin us_cnt <= 0; io_mode <= 1'b1; state <= S_REL; end
                    else us_cnt <= us_cnt + 1'b1;
                end
            end

            S_REL: begin
                io_mode <= 1'b1;
                if (!din && us_cnt > 2) begin us_cnt <= 0; state <= S_RESP_LOW; end
                else if (tick_us) us_cnt <= us_cnt + 1'b1;
                if (us_cnt > TIMEOUT_US) state <= S_DONE;
            end

            S_RESP_LOW: begin
                if (din) begin us_cnt <= 0; state <= S_RESP_HIGH; end
                else if (tick_us) us_cnt <= us_cnt + 1'b1;
                if (us_cnt > TIMEOUT_US) state <= S_DONE;
            end

            S_RESP_HIGH: begin
                if (!din) begin us_cnt <= 0; bit_cnt <= 0; state <= S_BIT_LOW; end
                else if (tick_us) us_cnt <= us_cnt + 1'b1;
                if (us_cnt > TIMEOUT_US) state <= S_DONE;
            end

            S_BIT_LOW: begin
                if (din) begin us_cnt <= 0; state <= S_BIT_HIGH; end
                else if (tick_us) us_cnt <= us_cnt + 1'b1;
                if (us_cnt > TIMEOUT_US) state <= S_DONE;
            end

            S_BIT_HIGH: begin
                if (!din) begin
                    data    <= {data[38:0], (us_cnt > BIT1_TH_US)};
                    bit_cnt <= bit_cnt + 1'b1;
                    us_cnt  <= 0;
                    state   <= (bit_cnt == 39) ? S_DONE : S_BIT_LOW;
                end else if (tick_us) us_cnt <= us_cnt + 1'b1;
                if (us_cnt > TIMEOUT_US) state <= S_DONE;
            end

            S_DONE: begin
                io_mode     <= 1'b1;
                done_toggle <= ~done_toggle;
                if (bit_cnt == 40 && chk == data[7:0]) begin
                    hum_int <= data[39:32];
                    hum_dec <= data[31:24];
                    tmp_int <= data[23:16];
                    tmp_dec <= data[15:8];
                    valid   <= 1'b1;
                end else begin
                    valid   <= 1'b0;                 // keep previous values
                end
                us_cnt  <= 0;
                bit_cnt <= 0;
                state   <= S_WAIT;
            end
            endcase
        end
    end

endmodule
