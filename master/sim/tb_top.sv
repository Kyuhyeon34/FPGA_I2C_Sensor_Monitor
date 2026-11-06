`timescale 1ns / 1ps

// Integration test against the user's actual i2c_slave + i2c_regs sources.
module tb_top;
    reg clk=0, reset=1, slave_reset=1;
    reg [1:0] btn=0;
    reg [7:0] sw=8'h3c;
    tri1 sda, scl;
    reg connected=1, force_sda_low=0, corrupt_id=0;
    assign sda = force_sda_low ? 1'b0 : 1'bz;
    wire [15:0] led;
    wire [7:0] seg;
    wire [3:0] an;
    wire RsTx;
    always #5 clk=~clk;
    top #(.CLOCK_HZ(1_000_000), .I2C_HZ(10_000), .BAUD(100_000),
          .DEBOUNCE_CYCLES(3), .OLED_ENABLE(0), .POLL_INTERVAL_CYCLES(0)) dut (.*);

    reg [7:0] hum_int=47, hum_dec=0, tmp_int=27, tmp_dec=7;
    reg [15:0] dist_cm=7;
    reg dht_valid=1, dist_valid=1;
    wire [7:0] reg_ptr, reg_data, wr_addr, wr_data, last_rx, user_reg;
    wire wr_en, snapshot, slave_busy, rx_toggle, tx_toggle;
    wire [7:0] slave_rd = (corrupt_id && reg_ptr==0) ? 8'h00 : reg_data;
    i2c_slave slave (
        .clk(clk), .reset(slave_reset), .scl(scl), .sda(sda),
        .reg_ptr(reg_ptr), .rd_data(slave_rd), .wr_en(wr_en),
        .wr_addr(wr_addr), .wr_data(wr_data), .start_pulse(snapshot),
        .busy(slave_busy), .rx_toggle(rx_toggle), .tx_toggle(tx_toggle), .last_rx(last_rx)
    );
    // Fault injection without changing the reference Slave source.
    always @(connected) begin
        if (!connected) force slave.sda_low = 1'b0;
        else release slave.sda_low;
    end
    i2c_regs regs (
        .clk(clk), .reset(slave_reset), .snapshot(snapshot),
        .hum_int(hum_int), .hum_dec(hum_dec), .tmp_int(tmp_int), .tmp_dec(tmp_dec),
        .dist_cm(dist_cm), .dht_valid(dht_valid), .dist_valid(dist_valid),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(reg_ptr), .rd_data(reg_data), .user_reg(user_reg)
    );
    integer starts=0, stops=0, checks=0;
    always @(negedge sda) if(scl === 1'b1 && !reset) starts=starts+1;
    always @(posedge sda) if(scl === 1'b1 && !reset) stops=stops+1;
    task press(input integer which);
        @(negedge clk); btn[which]=1;
        repeat(12) @(negedge clk); btn[which]=0;
    endtask
    task wait_start;
        do @(negedge sda); while(scl !== 1'b1);
    endtask
    task wait_stop;
        do @(posedge sda); while(scl !== 1'b1);
    endtask
    task receive_byte(output reg [7:0] value);
        integer b;
        for(b=7;b>=0;b=b-1) begin @(posedge scl); #1; value[b]=sda; end
    endtask
    task check_ack(input bit ack_expected);
        @(negedge scl); @(posedge scl); #1;
        if(sda !== !ack_expected) $fatal(1,"Wrong ACK/NACK: expected ACK=%b",ack_expected);
        @(negedge scl);
    endtask
    task receive_uart(output reg [7:0] value);
        integer b;
        @(negedge RsTx); #50;
        if(RsTx !== 0) $fatal(1,"UART start bit invalid");
        for(b=0;b<8;b=b+1) begin #100; value[b]=RsTx; end
        #100;
        if(RsTx !== 1) $fatal(1,"UART stop bit invalid");
    endtask
    task check_read(input [63:0] raw, input [15:0] expected_bcd,
                    input [7:0] expected_humidity, input bit valid_frame,
                    input [399:0] expected_line);
        reg [399:0] line;
        reg [7:0] value, serial_value;
        reg [15:0] previous_bcd;
        reg [15:0] previous_distance, expected_distance;
        integer b, c, old_starts, old_stops;
        previous_bcd=dut.display_bcd; old_starts=starts; old_stops=stops;
        previous_distance=dut.distance_cm;
        expected_distance=(raw[7:0]==8'ha5 && raw[57]) ? {raw[47:40],raw[55:48]} : previous_distance;
        fork
            begin
                press(0); wait(dut.printing); #1;
                if(led[15] !== valid_frame || led[14] !== !valid_frame || led[13])
                    $fatal(1,"Frame status incorrect");
                if(dut.display_bcd !== expected_bcd || led[7:0] !== expected_humidity)
                    $fatal(1,"Sensor display incorrect: %h",dut.display_bcd);
                if(dut.distance_cm !== expected_distance)
                    $fatal(1,"Distance decode/validity incorrect: %0d expected %0d",dut.distance_cm,expected_distance);
            end
            begin
                wait_start(); receive_byte(value);
                if(value !== 8'h84) $fatal(1,"Expected address+W");
                check_ack(1); receive_byte(value);
                if(value !== 8'h00) $fatal(1,"Each read must reset pointer to 0x00");
                check_ack(1);
                wait_start(); receive_byte(value);
                if(value !== 8'h85) $fatal(1,"Expected repeated START + address+R");
                check_ack(1);
                for(b=0;b<8;b=b+1) begin
                    receive_byte(value);
                    if(value !== raw[b*8 +: 8]) $fatal(1,"Register %0d mismatch: %h",b,value);
                    if(dut.display_bcd !== previous_bcd) $fatal(1,"Partial read changed FND");
                    if(dut.distance_cm !== previous_distance) $fatal(1,"Partial read changed distance");
                    check_ack(b != 7);
                end
                wait_stop();
            end
            begin
                for(c=0;c<50;c=c+1) begin
                    receive_uart(serial_value); line={line[391:0],serial_value};
                end
                if(line !== expected_line) $fatal(1,"UART text incorrect: %h",line);
            end
            begin
                wait(dut.reading_frame); repeat(100) @(negedge clk);
                press(0); press(1); // Ignored while a read is in progress.
            end
        join
        wait(!dut.printing); repeat(5) @(negedge clk);
        if(starts != old_starts+2 || stops != old_stops+1)
            $fatal(1,"Expected START + repeated START and exactly one STOP");
        if(reg_ptr !== 8'h08) $fatal(1,"Slave register pointer did not advance to 8");
        checks=checks+1;
    endtask
    initial begin
        reg [7:0] value;
        reg [15:0] previous_bcd;
        repeat(20) @(negedge clk); reset=0; slave_reset=0;
        repeat(20) @(negedge clk);
        if(led !== 0 || RsTx !== 1) $fatal(1,"Reset outputs incorrect");
        btn[0]=1; @(negedge clk); btn[0]=0;
        repeat(12) @(negedge clk);
        if(starts != 0) $fatal(1,"Button debounce failed");
        // Values changing mid-read must not tear the Slave's START snapshot.
        fork
            check_read(64'h030700071b002fa5,16'h4727,47,1,
                       {"H=047 T=027 D=00007cm RX=A5 2F 00 1B 07 00 07 03",8'h0d,8'h0a});
            begin
                wait(reg_ptr == 2); hum_int=60; hum_dec=0; tmp_int=23; tmp_dec=0; dist_cm=300;
            end
        join
        repeat(4) begin
            @(posedge clk); #1;
            case(an)
                4'b1110: if(seg !== 8'hf8) $fatal(1,"Temperature ones incorrect");
                4'b1101: if(seg !== 8'ha4) $fatal(1,"Temperature tens incorrect");
                4'b1011: if(seg !== 8'h78) $fatal(1,"Humidity ones/point incorrect");
                4'b0111: if(seg !== 8'h99) $fatal(1,"Humidity tens incorrect");
                default: $fatal(1,"Invalid FND anode");
            endcase
            repeat(1000) @(negedge clk);
        end
        // No Slave reset: the previous read left pointer=8, but this read starts at 0.
        check_read(64'h032c010017003ca5,16'h6023,60,1,
                   {"H=060 T=023 D=00300cm RX=A5 3C 00 17 00 01 2C 03",8'h0d,8'h0a});
        // USER write must send both register pointer 0x10 and switch data.
        fork
            begin press(1); wait(led[15]); #1;
                if(user_reg !== 8'h3c || last_rx !== 8'h3c || dut.display_bcd !== 16'h6023)
                    $fatal(1,"USER write or display preservation failed");
            end
            begin
                wait_start(); receive_byte(value);
                if(value !== 8'h84) $fatal(1,"Write address incorrect");
                check_ack(1); receive_byte(value);
                if(value !== 8'h10) $fatal(1,"USER register address incorrect");
                check_ack(1); receive_byte(value);
                if(value !== 8'h3c) $fatal(1,"Switch write data incorrect");
                check_ack(1); wait_stop();
            end
        join
        if(reg_ptr !== 8'h11) $fatal(1,"USER write pointer incorrect");
        check_read(64'h032c010017003ca5,16'h6023,60,1,
                   {"H=060 T=023 D=00300cm RX=A5 3C 00 17 00 01 2C 03",8'h0d,8'h0a});
        // Invalid DHT checksum must preserve the last valid sensor pair.
        dht_valid=0;
        check_read(64'h022c010017003ca5,16'h6023,60,0,
                   {"H=??? T=??? D=00300cm RX=A5 3C 00 17 00 01 2C 02",8'h0d,8'h0a});
        dht_valid=1; corrupt_id=1;
        check_read(64'h032c010017003c00,16'h6023,60,0,
                   {"H=??? T=??? D=?????cm RX=00 3C 00 17 00 01 2C 03",8'h0d,8'h0a});
        corrupt_id=0; hum_int=100; tmp_int=9;
        check_read(64'h032c0100090064a5,16'h9909,100,1,
                   {"H=100 T=009 D=00300cm RX=A5 64 00 09 00 01 2C 03",8'h0d,8'h0a});
        // Distance is an independent big-endian 16-bit sensor, not an 8-bit value.
        dist_valid=0; dist_cm=65535;
        check_read(64'h01ffff00090064a5,16'h9909,100,1,
                   {"H=100 T=009 D=?????cm RX=A5 64 00 09 00 FF FF 01",8'h0d,8'h0a});
        dist_valid=1;
        check_read(64'h03ffff00090064a5,16'h9909,100,1,
                   {"H=100 T=009 D=65535cm RX=A5 64 00 09 00 FF FF 03",8'h0d,8'h0a});
        dist_cm=256;
        check_read(64'h03000100090064a5,16'h9909,100,1,
                   {"H=100 T=009 D=00256cm RX=A5 64 00 09 00 01 00 03",8'h0d,8'h0a});
        dist_cm=255;
        check_read(64'h03ff0000090064a5,16'h9909,100,1,
                   {"H=100 T=009 D=00255cm RX=A5 64 00 09 00 00 FF 03",8'h0d,8'h0a});
        dist_cm=0;
        check_read(64'h03000000090064a5,16'h9909,100,1,
                   {"H=100 T=009 D=00000cm RX=A5 64 00 09 00 00 00 03",8'h0d,8'h0a});
        dht_valid=0; dist_cm=400;
        check_read(64'h02900100090064a5,16'h9909,100,0,
                   {"H=??? T=??? D=00400cm RX=A5 64 00 09 00 01 90 02",8'h0d,8'h0a});
        dht_valid=1;
        // Reset Master only: a fresh indexed read must still work.
        reset=1; repeat(8) @(negedge clk); reset=0; repeat(10) @(negedge clk);
        hum_int=45; tmp_int=27; dist_cm=7;
        check_read(64'h030700001b002da5,16'h4527,45,1,
                   {"H=045 T=027 D=00007cm RX=A5 2D 00 1B 00 00 07 03",8'h0d,8'h0a});
        previous_bcd=dut.display_bcd;
        connected=0;
        press(0); wait(led[14]); #1;
        if(!led[13] || led[15] || led[12] || dut.display_bcd !== previous_bcd)
            $fatal(1,"Address NACK handling incorrect");
        connected=1; repeat(20) @(negedge clk);
        // NACK on the read address after accepting the register pointer.
        fork
            begin press(0); wait(led[14]); end
            begin
                wait_start(); receive_byte(value); check_ack(1);
                receive_byte(value); check_ack(1); connected=0;
            end
        join
        if(!led[13] || dut.display_bcd !== previous_bcd) $fatal(1,"Read-address NACK handling failed");
        connected=1; slave_reset=1; repeat(20) @(negedge clk); slave_reset=0;
        // Stuck bus times out without modifying the sensor display.
        force_sda_low=1; repeat(20) @(negedge clk);
        press(0); wait(led[12]); wait(!led[12]); repeat(3) @(negedge clk);
        if(!led[14] || led[15] || led[13] || dut.display_bcd !== previous_bcd)
            $fatal(1,"Timeout handling incorrect");
        force_sda_low=0; repeat(20) @(negedge clk);
        // Recover without resetting the Master or manually aligning the pointer.
        check_read(64'h030700001b002da5,16'h4527,45,1,
                   {"H=045 T=027 D=00007cm RX=A5 2D 00 1B 00 00 07 03",8'h0d,8'h0a});
        $display("PASS: tb_top: %0d actual-Slave register reads, repeated START, burst ACK/NACK, snapshots, USER writes, FND, UART, ID/status, reset and error recovery",checks);
        $finish;
    end
    initial begin #8_000_000; $fatal(1,"Integration test watchdog timeout"); end
endmodule
