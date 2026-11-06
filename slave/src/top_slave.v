`timescale 1ns / 1ps
//==============================================================================
// top_slave : Basys3 I2C SLAVE board
//   DHT11 + HC-SR04 -> register file -> I2C slave (addr 0x42)
//   local output : FND (btnU toggles HH.TT / distance), UART 9600
//
//   LED
//     led[7:0] : last byte received from master
//     led[8]   : toggles on every received (write) byte
//     led[9]   : toggles on every transmitted (read) byte
//     led[10]  : DHT11 checksum OK
//     led[11]  : HC-SR04 valid
//     led[15]  : ON between START and STOP
//==============================================================================
module top_slave (
    input         clk,
    input         reset,        // btnC
    input         btn_mode,     // btnU

    // I2C (JA1 / JA2)
    input         scl,
    inout         sda,

    // sensors (JB)
    inout         dht11_data,
    output        trig,
    input         echo,

    output        RsTx,
    output [7:0]  seg,
    output [3:0]  an,
    output [15:0] led
);

    //------------------------------------------------------------ sensors
    wire [7:0]  hum_int, hum_dec, tmp_int, tmp_dec;
    wire [15:0] dist_cm;
    wire        dht_valid, dist_valid, dht_done;

    dht11_ctrl u_dht11 (
        .clk(clk), .reset(reset), .dht11_data(dht11_data),
        .hum_int(hum_int), .hum_dec(hum_dec), .tmp_int(tmp_int), .tmp_dec(tmp_dec),
        .valid(dht_valid), .done_toggle(dht_done)
    );

    hcsr04_ctrl u_hcsr04 (
        .clk(clk), .reset(reset), .trig(trig), .echo(echo),
        .dist_cm(dist_cm), .valid(dist_valid)
    );

    //------------------------------------------------------------ I2C slave
    wire [7:0] reg_ptr, rd_data, wr_addr, wr_data, last_rx, user_reg;
    wire       wr_en, start_pulse, i2c_busy, rx_toggle, tx_toggle;

    i2c_slave #(.SLAVE_ADDR(7'h42)) u_i2c (
        .clk(clk), .reset(reset), .scl(scl), .sda(sda),
        .reg_ptr(reg_ptr), .rd_data(rd_data),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .start_pulse(start_pulse),
        .busy(i2c_busy), .rx_toggle(rx_toggle), .tx_toggle(tx_toggle), .last_rx(last_rx)
    );

    i2c_regs u_regs (
        .clk(clk), .reset(reset), .snapshot(start_pulse),
        .hum_int(hum_int), .hum_dec(hum_dec), .tmp_int(tmp_int), .tmp_dec(tmp_dec),
        .dist_cm(dist_cm), .dht_valid(dht_valid), .dist_valid(dist_valid),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(reg_ptr), .rd_data(rd_data),
        .user_reg(user_reg)
    );

    //------------------------------------------------------------ button
    reg [19:0] db_cnt;
    reg [2:0]  btn_s;
    reg        mode;
    always @(posedge clk or posedge reset) begin
        if (reset) begin db_cnt <= 0; btn_s <= 0; mode <= 0; end
        else begin
            db_cnt <= db_cnt + 1'b1;
            if (db_cnt == 0) begin                   // sample every ~10ms
                btn_s <= {btn_s[1:0], btn_mode};
                if (btn_s[1:0] == 2'b01) mode <= ~mode;   // rising edge
            end
        end
    end

    //------------------------------------------------------------ outputs
    fnd_ctrl u_fnd (
        .clk(clk), .reset(reset), .mode(mode),
        .hum_int(hum_int), .tmp_int(tmp_int), .dist_cm(dist_cm),
        .seg(seg), .an(an)
    );

    uart_sensor_print u_uart (
        .clk(clk), .reset(reset),
        .hum_int(hum_int), .hum_dec(hum_dec), .tmp_int(tmp_int), .tmp_dec(tmp_dec),
        .dist_cm(dist_cm), .tx(RsTx)
    );

    assign led[7:0]   = last_rx;
    assign led[8]     = rx_toggle;
    assign led[9]     = tx_toggle;
    assign led[10]    = dht_valid;
    assign led[11]    = dist_valid;
    assign led[14:12] = 3'b000;
    assign led[15]    = i2c_busy;

endmodule
