`timescale 1ns / 1ps

// Actual sensor Slave + an SSD1306 command/GDDRAM model on the same SDA/SCL.
module tb_oled;
    reg clk=0, reset=1, slave_reset=1, sensor_reset=1;
    reg [1:0] btn=0;
    reg [7:0] sw=8'h55;
    tri1 scl, sda;
    wire [15:0] led;
    wire [7:0] seg;
    wire [3:0] an;
    wire RsTx;
    always #5 clk=~clk;
    top #(.CLOCK_HZ(1_000_000), .I2C_HZ(10_000), .BAUD(100_000),
          .DEBOUNCE_CYCLES(3), .OLED_POWERUP_CYCLES(20), .OLED_RETRY_CYCLES(1000),
          .POLL_INTERVAL_CYCLES(0)) dut(.*);

    reg [7:0] hum_int=47, tmp_int=27, tmp_dec=0;
    reg [15:0] dist_cm=7;
    reg dht_valid=1, dist_valid=1, corrupt_id=0;
    wire [7:0] sensor_ptr, sensor_rd, sensor_wr_addr, sensor_wr_data, user_reg;
    wire [7:0] sensor_data=(corrupt_id && sensor_ptr==0) ? 8'h00 : sensor_rd;
    wire sensor_wr_en, snapshot;
    i2c_slave sensor (
        .clk(clk), .reset(sensor_reset), .scl(scl), .sda(sda),
        .reg_ptr(sensor_ptr), .rd_data(sensor_data), .wr_en(sensor_wr_en),
        .wr_addr(sensor_wr_addr), .wr_data(sensor_wr_data), .start_pulse(snapshot),
        .busy(), .rx_toggle(), .tx_toggle(), .last_rx()
    );
    i2c_regs regs (
        .clk(clk), .reset(sensor_reset), .snapshot(snapshot),
        .hum_int(hum_int), .hum_dec(8'h00), .tmp_int(tmp_int), .tmp_dec(tmp_dec),
        .dist_cm(dist_cm), .dht_valid(dht_valid), .dist_valid(dist_valid),
        .wr_en(sensor_wr_en), .wr_addr(sensor_wr_addr), .wr_data(sensor_wr_data),
        .rd_addr(sensor_ptr), .rd_data(sensor_rd), .user_reg(user_reg)
    );
    // The reference I2C receiver supplies ACKs and decodes control/data writes.
    wire oled_wr_en;
    wire [7:0] oled_control, oled_byte;
    reg oled_connected=1;
    i2c_slave #(.SLAVE_ADDR(7'h3c)) oled_receiver (
        .clk(clk), .reset(slave_reset), .scl(scl), .sda(sda),
        .reg_ptr(), .rd_data(8'hff), .wr_en(oled_wr_en),
        .wr_addr(oled_control), .wr_data(oled_byte), .start_pulse(),
        .busy(), .rx_toggle(), .tx_toggle(), .last_rx()
    );
    always @(oled_connected) begin
        if(!oled_connected) force oled_receiver.sda_low=1'b0;
        else release oled_receiver.sda_low;
    end
    reg [7:0] ram[0:511];
    reg [7:0] sprite[0:511];
    reg [7:0] text_before[0:383];
    reg [7:0] command, mux, charge, com_pins, addressing;
    reg display_on=0;
    integer args=0, arg_index=0, column=0, page=0, column_start=0, icon_bytes=0;
    integer data_bytes=0, frames=0, commands=0, i;
    initial for(i=0;i<512;i=i+1) ram[i]=8'hff;
    initial $readmemh("slowpoke-frames.hex",sprite);
    always @(posedge clk) begin
        if(oled_wr_en) begin
            if(oled_control==8'h40) begin
                if(args != 0) $fatal(1,"OLED data interrupted a command argument");
                if(column>127 || page>3) $fatal(1,"OLED wrote outside 128x32 RAM");
                ram[page*128+column]=oled_byte;
                data_bytes=data_bytes+1;
                if(column_start==96) icon_bytes=icon_bytes+1;
                if(data_bytes%512==0) frames=frames+1;
                if(column==127) begin column=column_start; page=(page==3) ? 0 : page+1; end
                else column=column+1;
            end else if(oled_control==8'h00) begin
                commands=commands+1;
                if(args != 0) begin
                    case(command)
                        8'ha8: mux=oled_byte;
                        8'h8d: charge=oled_byte;
                        8'hda: com_pins=oled_byte;
                        8'h20: addressing=oled_byte;
                        8'h21: begin
                            if(arg_index==0) begin column=oled_byte; column_start=oled_byte; end
                            else if(oled_byte != 127) $fatal(1,"Wrong OLED last column");
                        end
                        8'h22: begin
                            if(arg_index==0) page=oled_byte;
                            else if(oled_byte != 3) $fatal(1,"Wrong OLED last page");
                        end
                    endcase
                    args=args-1; arg_index=arg_index+1;
                end else begin
                    command=oled_byte; arg_index=0;
                    case(oled_byte)
                        8'hd5,8'ha8,8'hd3,8'h8d,8'h20,8'hda,8'h81,8'hd9,8'hdb: args=1;
                        8'h21,8'h22: args=2;
                        8'hae: display_on=0;
                        8'haf: display_on=1;
                    endcase
                end
            end else $fatal(1,"Wrong SSD1306 control byte: %h",oled_control);
        end
    end
    task press(input integer which);
        @(negedge clk); btn[which]=1;
        repeat(12) @(negedge clk); btn[which]=0;
    endtask
    task read_sensor(input [15:0] expected_bcd);
        read_sensor_status(expected_bcd,1);
    endtask
    task read_sensor_status(input [15:0] expected_bcd, input bit valid_dht);
        press(0); wait(dut.reading_frame); wait(dut.printing); #1;
        if(led[15] !== valid_dht || led[14] !== !valid_dht || led[13] || dut.display_bcd !== expected_bcd)
            $fatal(1,"OLED bus activity corrupted sensor read");
        wait(!dut.printing);
    endtask
    task screen_idle;
        wait(dut.g_oled.u_display.state==5 && !dut.g_oled.u_display.pending && led[10]);
        repeat(5) @(negedge clk);
    endtask
    task check_layout;
        integer p,c;
        for(p=0;p<4;p=p+1)
            for(c=60;c<96;c=c+1)
                if(ram[p*128+c] !== 0) $fatal(1,"OLED right margin was not cleared");
        for(p=0;p<4;p=p+1)
            for(c=0;c<32;c=c+1)
                if(ram[p*128+96+c] !== sprite[dut.g_oled.u_display.animation_frame*128+p*32+c])
                    $fatal(1,"Slowpoke sprite incorrect at page %0d column %0d",p,c);
    endtask
    task check_distance(input [23:0] digits);
        reg [39:0] glyph;
        reg [7:0] ch;
        integer d,c;
        for(d=0;d<3;d=d+1) begin
            ch=digits[(2-d)*8 +: 8];
            case(ch)
                "0": glyph=40'h3e4549513e;
                "1": glyph=40'h00407f4200;
                "2": glyph=40'h4649516142;
                "3": glyph=40'h314b454121;
                "4": glyph=40'h107f121418;
                "5": glyph=40'h3945454527;
                "6": glyph=40'h3049494a3c;
                "7": glyph=40'h0305097101;
                "8": glyph=40'h3649494936;
                "9": glyph=40'h1e29494906;
                "-": glyph=40'h0808080808;
                default: glyph=0;
            endcase
            for(c=0;c<5;c=c+1)
                if(ram[384+30+d*6+c] !== glyph[c*8 +: 8])
                    $fatal(1,"Distance raster mismatch for %s at digit %0d column %0d",digits,d,c);
            if(ram[384+35+d*6] !== 0) $fatal(1,"Distance glyph spacing incorrect");
        end
        if(ram[384] !== 8'h7f || ram[384+48] !== 8'h38 || ram[384+54] !== 8'h7c)
            $fatal(1,"DIST label/cm unit incorrect");
    endtask
    task check_temperature(input [39:0] text);
        reg [39:0] glyph;
        reg [7:0] ch, column_byte;
        integer d,c;
        // TEMP starts at y=12: each glyph spans OLED RAM pages 1 and 2.
        for(d=0;d<5;d=d+1) begin
            ch=text[(4-d)*8 +: 8];
            case(ch)
                "0": glyph=40'h3e4549513e;
                "1": glyph=40'h00407f4200;
                "2": glyph=40'h4649516142;
                "3": glyph=40'h314b454121;
                "4": glyph=40'h107f121418;
                "5": glyph=40'h3945454527;
                "6": glyph=40'h3049494a3c;
                "7": glyph=40'h0305097101;
                "8": glyph=40'h3649494936;
                "9": glyph=40'h1e29494906;
                ".": glyph=40'h0000606000;
                "?": glyph=40'h0609510102;
                "C": glyph=40'h224141413e;
                "-": glyph=40'h0808080808;
                default: $fatal(1,"Invalid expected temperature character");
            endcase
            for(c=0;c<5;c=c+1) begin
                column_byte=glyph[c*8 +: 8];
                if(ram[128+30+d*6+c] !== {column_byte[3:0],4'b0000} ||
                   ram[256+30+d*6+c] !== {4'b0000,column_byte[7:4]})
                    $fatal(1,"Temperature raster mismatch: %s digit %0d column %0d",text,d,c);
            end
            if(ram[128+35+d*6]!==0 || ram[256+35+d*6]!==0)
                $fatal(1,"Temperature glyph spacing incorrect");
        end
    endtask
    initial begin
        integer initial_commands, step, p, c, old_icon_bytes;
        repeat(20) @(negedge clk); reset=0; slave_reset=0;
        // No sensor Slave response and no button presses: the initial screen
        // must still contain Slowpoke, with two dash placeholders per value.
        screen_idle();
        if(dut.g_oled.u_display.draw_valid || led[15:13] || dut.display_bcd !== 0)
            $fatal(1,"Initial mascot screen depended on a sensor result");
        if(ram[24]!==8'h08 || ram[30]!==8'h08 ||
           ram[128+30]!==8'h80 || ram[256+30]!==0)
            $fatal(1,"Initial HUM:--%% / TEMP:--C placeholders incorrect");
        check_distance("---");
        check_temperature("--.-C");
        check_layout();
        $writememh("oled_boot_screen.hex",ram);
        $writememh("oled_animation_0.hex",ram);
        for(p=0;p<4;p=p+1)
            for(c=0;c<96;c=c+1) text_before[p*96+c]=ram[p*128+c];
        // Autonomous animation works without sensor replies; only 128 icon
        // bytes may be written per step and all text pixels must stay unchanged.
        for(step=1;step<4;step=step+1) begin
            old_icon_bytes=icon_bytes;
            wait(dut.g_oled.u_display.animation_frame==step);
            screen_idle(); check_layout();
            if(icon_bytes!=old_icon_bytes+128) $fatal(1,"Animation did not use a 128-byte partial update");
            for(p=0;p<4;p=p+1)
                for(c=0;c<96;c=c+1)
                    if(text_before[p*96+c] !== ram[p*128+c]) $fatal(1,"Animation changed sensor text");
            $writememh($sformatf("oled_animation_%0d.hex",step),ram);
        end
        sensor_reset=0;
        reset=1; repeat(8) @(negedge clk); reset=0;
        initial_commands=commands;
        // User request during OLED initialization must be queued and served.
        wait(commands>=initial_commands+3); read_sensor(16'h4727); screen_idle();
        if(mux !== 31 || charge !== 8'h14 || com_pins !== 2 || addressing !== 0 || !display_on)
            $fatal(1,"SSD1306 128x32 initialization incorrect");
        if(frames<1 || led[11]) $fatal(1,"OLED did not initialize");
        // Three text rows: H/T remain two digits and distance uses both bytes.
        if(ram[0]!==8'h7f || ram[24]!==8'h18 || ram[30]!==8'h01 ||
           ram[128+30]!==8'h20 || ram[256+30]!==8'h04 || ram[128+36]!==8'h10)
            $fatal(1,"OLED HUM:47%% / TEMP:27C raster incorrect");
        check_distance("  7");
        check_temperature("27.0C");
        check_layout();
        // Updating during rendering must retain the current snapshot, then draw
        // the newest queued sample. Sensor operations keep priority on the bus.
        hum_int=60; tmp_int=23; dist_cm=256; read_sensor(16'h6023);
        wait(dut.g_oled.u_display.state==3);
        hum_int=55; tmp_int=24; dist_cm=300; read_sensor(16'h5524); screen_idle();
        if(ram[24]!==8'h27 || ram[30]!==8'h27 || // humidity 55
           ram[128+36]!==8'h80 || ram[256+36]!==8'h01) // temperature ones 4
            $fatal(1,"OLED did not render newest queued sample");
        check_distance("300");
        check_layout();
        $writememh("oled_screen.hex",ram);
        // Each sensor has its own validity bit. Invalid samples retain history.
        dht_valid=0; hum_int=99; tmp_int=99; dist_cm=65535;
        read_sensor_status(16'h5524,0); screen_idle();
        check_distance("999");
        if(ram[24]!==8'h27 || ram[128+36]!==8'h80)
            $fatal(1,"Invalid DHT changed previous H/T");
        // Leading blanks and saturation boundaries must survive full redraws.
        dist_cm=99; read_sensor_status(16'h5524,0); screen_idle(); check_distance(" 99");
        dist_cm=100; read_sensor_status(16'h5524,0); screen_idle(); check_distance("100");
        dist_cm=999; read_sensor_status(16'h5524,0); screen_idle(); check_distance("999");
        dist_cm=1000; read_sensor_status(16'h5524,0); screen_idle(); check_distance("999");
        dist_valid=0; dist_cm=0; read_sensor_status(16'h5524,0); screen_idle();
        check_distance("999");
        corrupt_id=1; dht_valid=1; dist_valid=1;
        read_sensor_status(16'h5524,0); screen_idle(); check_distance("999");
        corrupt_id=0; hum_int=55; tmp_int=24;
        dist_valid=0; read_sensor(16'h5524); screen_idle(); check_distance("999");
        dist_valid=1; read_sensor(16'h5524); screen_idle(); check_distance("  0");
        // First sample can contain only distance; H/T must remain placeholders.
        reset=1; repeat(8) @(negedge clk); reset=0;
        dht_valid=0; dist_cm=256;
        read_sensor_status(16'h0000,0); screen_idle(); check_distance("256");
        if(ram[24]!==8'h08 || ram[30]!==8'h08 || !dut.g_oled.u_display.draw_distance_valid)
            $fatal(1,"Distance depended on DHT readiness");
        $writememh("oled_distance_only.hex",ram);
        dht_valid=1;
        // Unplugged OLED must not set the sensor NACK/FAIL indicators.
        oled_connected=0; hum_int=47; tmp_int=27;
        read_sensor(16'h4727); wait(led[11]);
        if(led[14:13] || !led[15]) $fatal(1,"OLED NACK leaked into sensor status");
        press(1);
        if(!dut.distance_mode || dut.fnd_bcd!==16'h0256 || dut.fnd_dots!==0 || user_reg!==0)
            $fatal(1,"OLED fault blocked local FND mode change");
        read_sensor(16'h4727);
        oled_connected=1; screen_idle();
        if(led[11] || !led[10] || !display_on || ram[24]!==8'h18 || ram[30]!==8'h01)
            $fatal(1,"OLED reconnect/retry failed");
        check_distance("256");
        check_layout();
        // Decimal temperature uses the received 0x04 byte, with the same snapshot/validity.
        hum_int=36; tmp_int=28; tmp_dec=4; dist_cm=3;
        read_sensor(16'h3628); screen_idle();
        check_temperature("28.4C"); check_distance("  3"); check_layout();
        $writememh("oled_decimal.hex",ram);
        dht_valid=0; tmp_dec=9;
        read_sensor_status(16'h3628,0); screen_idle(); check_temperature("28.4C");
        dht_valid=1; tmp_dec=0;
        read_sensor(16'h3628); screen_idle(); check_temperature("28.0C");
        tmp_dec=9;
        read_sensor(16'h3628); screen_idle(); check_temperature("28.9C");
        tmp_dec=255;
        read_sensor(16'h3628); screen_idle(); check_temperature("28.?C");
        tmp_dec=4;
        read_sensor(16'h3628); screen_idle(); check_temperature("28.4C");
        check_distance("  3"); check_layout();
        $writememh("oled_screen.hex",ram);
        $display("PASS: tb_oled: decimal temperature 28.4/0/9/invalid, glyph pixels and validity, distance boundaries, snapshots, Slowpoke animation, shared bus and reconnect");
        $finish;
    end
    initial begin #450_000_000; $fatal(1,"OLED test watchdog timeout"); end
endmodule
