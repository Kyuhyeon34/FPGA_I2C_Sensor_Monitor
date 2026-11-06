`timescale 1ns / 1ps
//==============================================================================
// i2c_regs : register map seen by the I2C master
//
//  0x00 WHO_AM_I   (RO) 0xA5
//  0x01 HUM_INT    (RO)
//  0x02 HUM_DEC    (RO)
//  0x03 TMP_INT    (RO)
//  0x04 TMP_DEC    (RO)
//  0x05 DIST_H     (RO) distance[15:8] (cm)
//  0x06 DIST_L     (RO) distance[7:0]
//  0x07 STATUS     (RO) bit0: DHT11 checksum OK, bit1: HC-SR04 valid
//  0x10 USER       (RW) written by master -> slave LED
//  others          0x00
//
//  Sensor values are latched at every START so a multi-byte read is consistent.
//==============================================================================
module i2c_regs #(
    parameter [7:0] WHO_AM_I = 8'hA5
)(
    input            clk,
    input            reset,
    input            snapshot,

    input      [7:0] hum_int,
    input      [7:0] hum_dec,
    input      [7:0] tmp_int,
    input      [7:0] tmp_dec,
    input      [15:0] dist_cm,
    input            dht_valid,
    input            dist_valid,

    input            wr_en,
    input      [7:0] wr_addr,
    input      [7:0] wr_data,

    input      [7:0] rd_addr,
    output reg [7:0] rd_data,

    output reg [7:0] user_reg
);

    reg [7:0]  s_hum_int, s_hum_dec, s_tmp_int, s_tmp_dec;
    reg [15:0] s_dist;
    reg [1:0]  s_status;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            s_hum_int <= 0; s_hum_dec <= 0;
            s_tmp_int <= 0; s_tmp_dec <= 0;
            s_dist    <= 0; s_status  <= 0;
            user_reg  <= 0;
        end else begin
            if (snapshot) begin
                s_hum_int <= hum_int;
                s_hum_dec <= hum_dec;
                s_tmp_int <= tmp_int;
                s_tmp_dec <= tmp_dec;
                s_dist    <= dist_cm;
                s_status  <= {dist_valid, dht_valid};
            end
            if (wr_en && wr_addr == 8'h10)
                user_reg <= wr_data;
        end
    end

    always @(*) begin
        case (rd_addr)
            8'h00:   rd_data = WHO_AM_I;
            8'h01:   rd_data = s_hum_int;
            8'h02:   rd_data = s_hum_dec;
            8'h03:   rd_data = s_tmp_int;
            8'h04:   rd_data = s_tmp_dec;
            8'h05:   rd_data = s_dist[15:8];
            8'h06:   rd_data = s_dist[7:0];
            8'h07:   rd_data = {6'd0, s_status};
            8'h10:   rd_data = user_reg;
            default: rd_data = 8'h00;
        endcase
    end

endmodule
