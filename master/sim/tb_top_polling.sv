`timescale 1ns / 1ps

// Automatic polling with the real sensor register protocol, UART and shared OLED bus.
module tb_top_polling #(
    parameter integer POLL_CYCLES = 100_000
);
    reg clk=0, reset=1, slave_reset=1;
    reg [1:0] btn=0;
    reg [7:0] sw=8'h5a;
    tri1 sda, scl;
    wire [15:0] led;
    wire [7:0] seg;
    wire [3:0] an;
    wire RsTx;
    always #5 clk=~clk;
    top #(.CLOCK_HZ(1_000_000), .I2C_HZ(10_000), .BAUD(9600),
          .DEBOUNCE_CYCLES(3), .OLED_POWERUP_CYCLES(20),
          .OLED_RETRY_CYCLES(1000), .POLL_INTERVAL_CYCLES(POLL_CYCLES)) dut(.*);

    reg [7:0] hum_int=47, tmp_int=27;
    reg [15:0] dist_cm=7;
    reg dht_valid=1, dist_valid=1, connected=1, force_sda_low=0;
    assign sda = force_sda_low ? 1'b0 : 1'bz;
    wire [7:0] reg_ptr, reg_data, wr_addr, wr_data, user_reg;
    wire wr_en, snapshot;
    i2c_slave sensor (
        .clk(clk), .reset(slave_reset), .scl(scl), .sda(sda),
        .reg_ptr(reg_ptr), .rd_data(reg_data), .wr_en(wr_en),
        .wr_addr(wr_addr), .wr_data(wr_data), .start_pulse(snapshot),
        .busy(), .rx_toggle(), .tx_toggle(), .last_rx()
    );
    always @(connected) begin
        if (!connected) force sensor.sda_low=1'b0;
        else release sensor.sda_low;
    end
    i2c_regs regs (
        .clk(clk), .reset(slave_reset), .snapshot(snapshot),
        .hum_int(hum_int), .hum_dec(8'h00), .tmp_int(tmp_int), .tmp_dec(8'h00),
        .dist_cm(dist_cm), .dht_valid(dht_valid), .dist_valid(dist_valid),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(reg_ptr), .rd_data(reg_data), .user_reg(user_reg)
    );
    wire oled_wr_en;
    wire [7:0] oled_control, oled_byte;
    i2c_slave #(.SLAVE_ADDR(7'h3c)) oled_receiver (
        .clk(clk), .reset(slave_reset), .scl(scl), .sda(sda),
        .reg_ptr(), .rd_data(8'hff), .wr_en(oled_wr_en),
        .wr_addr(oled_control), .wr_data(oled_byte), .start_pulse(),
        .busy(), .rx_toggle(), .tx_toggle(), .last_rx()
    );

    integer cycle=0, previous_read=-1, reads=0, uart_lines=0, oled_bytes=0;
    reg [63:0] uart_snapshot;
    reg [399:0] uart_line;
    reg [7:0] serial_byte;
    integer c, b;
    // Check cadence at the actual grant, including waits for OLED byte boundaries.
    always @(negedge clk) begin
        if(dut.rst) begin
            cycle=0; previous_read=-1;
        end else begin
            cycle=cycle+1;
            if(dut.master_start && dut.bus_owner==1 && dut.master_read) begin
                if(dut.printing) $fatal(1,"Poll overwrote an active UART snapshot");
                if(previous_read>=0 && cycle-previous_read<POLL_CYCLES)
                    $fatal(1,"Automatic poll ran before its interval");
                if(previous_read>=0 && cycle-previous_read>POLL_CYCLES+70_000)
                    $fatal(1,"Automatic polling stalled");
                if(previous_read<0 && cycle>20) $fatal(1,"First automatic read was delayed");
                previous_read=cycle;
                reads=reads+1;
            end
            if(oled_wr_en && oled_control==8'h40) oled_bytes=oled_bytes+1;
        end
    end
    // Decode every physical UART line to catch overlapping or truncated output.
    initial forever begin
        wait(dut.printing);
        uart_snapshot=dut.print_data;
        uart_line=0;
        for(c=0;c<50;c=c+1) begin
            @(negedge RsTx); #520;
            if(RsTx !== 0) $fatal(1,"UART start bit invalid during polling");
            for(b=0;b<8;b=b+1) begin #1040; serial_byte[b]=RsTx; end
            #1040;
            if(RsTx !== 1) $fatal(1,"UART stop bit invalid during polling");
            uart_line={uart_line[391:0],serial_byte};
            if(dut.print_data !== uart_snapshot) $fatal(1,"UART snapshot changed mid-line");
        end
        if(uart_line[399:384] !== "H=" || uart_line[303:288] !== "D=" ||
           uart_line[223:200] !== "RX=" || uart_line[15:0] !== 16'h0d0a)
            $fatal(1,"Automatic UART line framing incorrect: %h",uart_line);
        uart_lines=uart_lines+1;
        wait(!dut.printing);
    end

    task next_frame(input [15:0] expected_bcd, input [15:0] expected_distance,
                    input bit valid_dht);
        @(posedge dut.printing); #1;
        if(dut.display_bcd !== expected_bcd || dut.distance_cm !== expected_distance ||
           led[15] !== valid_dht || led[14] !== !valid_dht || led[13])
            $fatal(1,"Automatic sensor update incorrect: FND=%h distance=%0d flags=%h",
                   dut.display_bcd,dut.distance_cm,led);
        wait(!dut.printing);
    endtask
    task press_write;
        @(negedge clk); btn[1]=1;
        repeat(12) @(negedge clk); btn[1]=0;
    endtask

    initial begin
        repeat(20) @(negedge clk); reset=0; slave_reset=0;
        next_frame(16'h4727,7,1); // No read button anywhere in this test.
        if(uart_line !== {"H=047 T=027 D=00007cm RX=A5 2F 00 1B 00 00 07 03",8'h0d,8'h0a})
            $fatal(1,"First automatic UART values incorrect");
        hum_int=60; tmp_int=23; dist_cm=300;
        next_frame(16'h6023,300,1);
        if(uart_line !== {"H=060 T=023 D=00300cm RX=A5 3C 00 17 00 01 2C 03",8'h0d,8'h0a})
            $fatal(1,"Changed sensors did not reach UART automatically");
        dht_valid=0; hum_int=12; tmp_int=34; dist_cm=400;
        next_frame(16'h6023,400,0);
        dht_valid=1; dist_valid=0; dist_cm=65535;
        next_frame(16'h1234,400,1);
        dist_valid=1;
        next_frame(16'h1234,65535,1);

        // A human write arriving with a due poll must win; polling resumes after it.
        wait(dut.bus_owner==2 && !dut.sensor_pending);
        force dut.poll_count=POLL_CYCLES-2;
        fork
            press_write();
            begin
                wait(dut.write_pulse);
                force dut.poll_count=POLL_CYCLES-1;
                @(posedge clk); #1;
                if(!dut.sensor_pending || dut.pending_read)
                    $fatal(1,"Automatic poll took priority over USER write");
                release dut.poll_count;
            end
        join
        wait(user_reg==8'h5a);
        next_frame(16'h1234,65535,1);

        // Keep good values on disconnection, then recover without a button or reset.
        connected=0;
        wait(dut.done && dut.bus_owner==1); @(posedge clk); #1;
        if(!led[14] || !led[13] || dut.display_bcd!==16'h1234 || dut.distance_cm!==65535)
            $fatal(1,"Automatic NACK did not preserve previous readings");
        connected=1; hum_int=45; tmp_int=26; dist_cm=256;
        next_frame(16'h4526,256,1);

        // Stuck bus timeout must also leave the next automatic attempt enabled.
        wait(dut.bus_owner==0 && !dut.busy);
        force_sda_low=1;
        wait(dut.done && dut.bus_owner==1 && dut.timeout_error); @(posedge clk); #1;
        if(!led[14] || dut.display_bcd!==16'h4526 || dut.distance_cm!==256)
            $fatal(1,"Automatic timeout did not preserve previous readings");
        force_sda_low=0;
        next_frame(16'h4526,256,1);

        // Automatic traffic must allow the OLED to initialize and draw fresh values.
        wait(led[10] && oled_bytes>=1024);
        if(led[11] || !dut.g_oled.u_display.latest_valid ||
           dut.g_oled.u_display.latest_h!==45 ||
           dut.g_oled.u_display.latest_t!==26 ||
           dut.g_oled.u_display.latest_distance!==20'h00256)
            $fatal(1,"OLED was starved or did not receive automatically refreshed values");
        wait(!dut.printing && dut.bus_owner==0 && !dut.busy);
        reset=1; repeat(8) @(negedge clk); reset=0;
        hum_int=48; tmp_int=28; dist_cm=99;
        next_frame(16'h4828,99,1);
        if(reads<10 || uart_lines<8) $fatal(1,"Not enough automatic transactions exercised");
        $display("PASS: tb_top_polling: interval=%0d, %0d reads, %0d UART lines, OLED progress, USER write priority, validity, NACK/timeout recovery and reset",POLL_CYCLES,reads,uart_lines);
        $finish;
    end
    initial begin #60_000_000; $fatal(1,"Automatic polling watchdog timeout"); end
endmodule

// A shorter-than-UART interval exercises a due poll waiting for a complete line.
module tb_top_polling_fast;
    tb_top_polling #(.POLL_CYCLES(1)) test();
endmodule
