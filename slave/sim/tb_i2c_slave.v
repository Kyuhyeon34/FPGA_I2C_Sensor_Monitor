`timescale 1ns / 1ps
//==============================================================================
// tb_i2c_slave : behavioral I2C master (100kHz) vs i2c_slave + i2c_regs
//==============================================================================
module tb_i2c_slave;

    reg clk = 0, reset = 1;
    always #5 clk = ~clk;                  // 100MHz

    // open-drain bus with pull-ups
    wire scl, sda;
    reg  m_scl_low = 0, m_sda_low = 0;
    assign scl = m_scl_low ? 1'b0 : 1'bz;
    assign sda = m_sda_low ? 1'b0 : 1'bz;
    pullup(scl);
    pullup(sda);

    // DUT
    wire [7:0] reg_ptr, rd_data, wr_addr, wr_data, last_rx, user_reg;
    wire       wr_en, start_pulse, busy, rx_toggle, tx_toggle;

    i2c_slave #(.SLAVE_ADDR(7'h42)) dut (
        .clk(clk), .reset(reset), .scl(scl), .sda(sda),
        .reg_ptr(reg_ptr), .rd_data(rd_data),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .start_pulse(start_pulse),
        .busy(busy), .rx_toggle(rx_toggle), .tx_toggle(tx_toggle), .last_rx(last_rx)
    );

    i2c_regs u_regs (
        .clk(clk), .reset(reset), .snapshot(start_pulse),
        .hum_int(8'd45), .hum_dec(8'd0), .tmp_int(8'd23), .tmp_dec(8'd1),
        .dist_cm(16'h0123), .dht_valid(1'b1), .dist_valid(1'b1),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(reg_ptr), .rd_data(rd_data), .user_reg(user_reg)
    );

    //--------------------------------------------------------------------------
    // I2C master BFM
    //--------------------------------------------------------------------------
    localparam Q = 2500;                   // quarter of 10us SCL period

    task i2c_start;                        // works for START and repeated START
        begin
            m_sda_low = 0; #Q;
            m_scl_low = 0; #Q;
            m_sda_low = 1; #Q;
            m_scl_low = 1; #Q;
        end
    endtask

    task i2c_stop;
        begin
            m_sda_low = 1; #Q;
            m_scl_low = 0; #Q;
            m_sda_low = 0; #Q;
        end
    endtask

    task write_bit(input b);
        begin
            m_sda_low = ~b; #Q;
            m_scl_low = 0;  #(2*Q);
            m_scl_low = 1;  #Q;
        end
    endtask

    task read_bit(output b);
        begin
            m_sda_low = 0; #Q;
            m_scl_low = 0; #Q;
            b = sda;       #Q;
            m_scl_low = 1; #Q;
        end
    endtask

    task write_byte(input [7:0] d, output ack);
        integer i; reg nack;
        begin
            for (i = 7; i >= 0; i = i - 1) write_bit(d[i]);
            read_bit(nack);
            ack = ~nack;
        end
    endtask

    task read_byte(output [7:0] d, input send_ack);
        integer i; reg b;
        begin
            for (i = 7; i >= 0; i = i - 1) begin read_bit(b); d[i] = b; end
            write_bit(~send_ack);
        end
    endtask

    //--------------------------------------------------------------------------
    // checks
    //--------------------------------------------------------------------------
    integer errors = 0;
    task check(input [255:0] name, input [7:0] got, input [7:0] exp);
        begin
            if (got === exp) $display("[PASS] %0s : 0x%02h", name, got);
            else begin $display("[FAIL] %0s : got 0x%02h, exp 0x%02h", name, got, exp); errors = errors + 1; end
        end
    endtask

    // high-level transactions
    task reg_write(input [6:0] addr, input [7:0] ptr, input [7:0] d, output ok);
        reg a0, a1, a2;
        begin
            i2c_start;
            write_byte({addr, 1'b0}, a0);
            write_byte(ptr, a1);
            write_byte(d,   a2);
            i2c_stop;
            ok = a0 & a1 & a2;
        end
    endtask

    reg [7:0] buf_ [0:15];
    task reg_read(input [6:0] addr, input [7:0] ptr, input integer n, output ok);
        reg a0, a1, a2; integer k;
        begin
            i2c_start;
            write_byte({addr, 1'b0}, a0);
            write_byte(ptr, a1);
            i2c_start;                                   // repeated START
            write_byte({addr, 1'b1}, a2);
            for (k = 0; k < n; k = k + 1)
                read_byte(buf_[k], (k != n-1));          // last byte : NACK
            i2c_stop;
            ok = a0 & a1 & a2;
        end
    endtask

    reg ok, ack, rx_t0, tx_t0;
    initial begin
        $display("==== tb_i2c_slave start ====");
        #200 reset = 0;
        #1000;

        // 1. WHO_AM_I
        reg_read(7'h42, 8'h00, 1, ok);
        check("T1 addr ACK", ok, 1'b1);
        check("T1 WHO_AM_I", buf_[0], 8'hA5);

        // 2. write USER reg
        rx_t0 = rx_toggle;
        reg_write(7'h42, 8'h10, 8'h5A, ok);
        check("T2 write ACK", ok, 1'b1);
        check("T2 user_reg", user_reg, 8'h5A);
        check("T2 last_rx (led[7:0])", last_rx, 8'h5A);
        check("T2 led[8] toggled", rx_toggle ^ rx_t0, 1'b1);

        // 3. read back
        reg_read(7'h42, 8'h10, 1, ok);
        check("T3 read back", buf_[0], 8'h5A);

        // 4. burst read sensor regs 0x01~0x07
        tx_t0 = tx_toggle;
        reg_read(7'h42, 8'h01, 7, ok);
        check("T4 HUM_INT", buf_[0], 8'd45);
        check("T4 HUM_DEC", buf_[1], 8'd0);
        check("T4 TMP_INT", buf_[2], 8'd23);
        check("T4 TMP_DEC", buf_[3], 8'd1);
        check("T4 DIST_H",  buf_[4], 8'h01);
        check("T4 DIST_L",  buf_[5], 8'h23);
        check("T4 STATUS",  buf_[6], 8'h03);
        check("T4 led[9] toggled 7x", tx_toggle ^ tx_t0, 1'b1);

        // 5. wrong address -> NACK
        i2c_start;
        write_byte({7'h43, 1'b0}, ack);
        i2c_stop;
        check("T5 wrong addr NACK", ack, 1'b0);

        // 6. bus still works after NACK
        reg_read(7'h42, 8'h00, 1, ok);
        check("T6 WHO_AM_I again", buf_[0], 8'hA5);

        // 7. busy (led[15]) low after STOP
        #2000;
        check("T7 busy after STOP", busy, 1'b0);

        if (errors == 0) $display("==== ALL TESTS PASSED ====");
        else             $display("==== %0d TEST(S) FAILED ====", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
