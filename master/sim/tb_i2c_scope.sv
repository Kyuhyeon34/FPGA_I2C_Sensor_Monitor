`timescale 1ns / 1ps

// Scope-style digital captures of separate two-byte sensor register reads.
// The board top is unchanged. This bench uses the real Master and Slave RTL.
module tb_i2c_scope #(
    parameter integer SENSOR_SELECT = 0, // 0=sequence, 1=temp, 2=humidity, 3=distance
    parameter OUTPUT_PREFIX = "i2c_scope"
);
    reg clk=0, reset=1, start=0;
    reg [7:0] reg_addr=0;
    wire [7:0] rx_data;
    wire [15:0] rx_frame;
    wire busy, done, nack_error, timeout_error;
    tri1 scl, sda;
    always #5 clk=~clk;

    i2c_master #(.CLOCK_HZ(100_000_000), .I2C_HZ(100_000),
                 .REGISTER_MODE(1), .READ_BYTES(2)) dut (
        .clk(clk), .reset(reset), .start(start), .slave_addr(7'h42),
        .read_not_write(1'b1), .tx_data(8'h00), .reg_addr(reg_addr),
        .rx_data(rx_data), .rx_frame(rx_frame), .busy(busy), .done(done),
        .nack_error(nack_error), .timeout_error(timeout_error), .scl(scl), .sda(sda)
    );

    reg [7:0] hum_int=36, hum_dec=0, tmp_int=28, tmp_dec=4;
    reg [15:0] dist_cm=3;
    wire [7:0] reg_ptr, rd_data, wr_addr, wr_data;
    wire wr_en, snapshot;
    i2c_slave slave (
        .clk(clk), .reset(reset), .scl(scl), .sda(sda),
        .reg_ptr(reg_ptr), .rd_data(rd_data), .wr_en(wr_en),
        .wr_addr(wr_addr), .wr_data(wr_data), .start_pulse(snapshot),
        .busy(), .rx_toggle(), .tx_toggle(), .last_rx()
    );
    i2c_regs regs (
        .clk(clk), .reset(reset), .snapshot(snapshot),
        .hum_int(hum_int), .hum_dec(hum_dec), .tmp_int(tmp_int), .tmp_dec(tmp_dec),
        .dist_cm(dist_cm), .dht_valid(1'b1), .dist_valid(1'b1),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(reg_ptr), .rd_data(rd_data), .user_reg()
    );

    // Add these names to the waveform viewer; ASCII labels explain each region.
    reg [127:0] capture_label="IDLE", bus_stage="IDLE";
    reg [127:0] byte_label="IDLE";
    reg [1:0] sensor_kind=0;
    reg [15:0] sample_value=0;
    reg [7:0] expected_byte0=0, expected_byte1=0, decoded_byte=0;
    reg [3:0] byte_number=0, bit_number=0;
    integer capture_no=0, checks=0, starts=0, stops=0;
    integer edges_file=0, bytes_file=0, captures_file=0, events_file=0;

    function [7:0] hex_char(input [3:0] value);
        hex_char=(value<10) ? 8'h30+value : 8'h41+value-10;
    endfunction

    always @(scl or sda) begin
        if(edges_file!=0)
            $fwrite(edges_file,"%0.3f,%b,%b\n",$realtime,scl,sda);
    end
    always @(negedge sda) if(scl===1'b1 && !reset) starts=starts+1;
    always @(posedge sda) if(scl===1'b1 && !reset) stops=stops+1;

    task start_condition(input bit repeated);
        do @(negedge sda); while(scl!==1'b1);
        bus_stage=repeated ? "RESTART" : "START";
        $fwrite(events_file,"%0d,%0.3f,%0s\n",capture_no,$realtime,bus_stage);
    endtask

    task check_byte(input integer index, input [127:0] label,
                    input [7:0] expected, input bit expect_ack);
        reg [7:0] actual;
        real byte_begin;
        integer b;
        byte_number=index;
        bus_stage=label;
        byte_begin=$realtime;
        for(b=7;b>=0;b=b-1) begin
            @(posedge scl); #1;
            bit_number=8-b;
            actual[b]=sda;
        end
        decoded_byte=actual;
        byte_label={label[103:0],8'h20,hex_char(actual[7:4]),hex_char(actual[3:0])};
        if(actual!==expected)
            $fatal(1,"Capture %0d byte %0d: got %02h expected %02h",capture_no,index,actual,expected);
        @(negedge scl);
        bit_number=9;
        if(index<=3) bus_stage="SLAVE_ACK";
        else bus_stage=expect_ack ? "MASTER_ACK" : "MASTER_NACK";
        @(posedge scl); #1;
        if(sda!==!expect_ack)
            $fatal(1,"Capture %0d byte %0d: ACK/NACK incorrect",capture_no,index);
        $fwrite(bytes_file,"%0d,%0d,%0s,%0.3f,%0.3f,%02h,%0d\n",
                capture_no,index,label,byte_begin,$realtime,actual,expect_ack);
        @(negedge scl);
    endtask

    task capture_read(input [1:0] kind, input [127:0] label,
                      input [7:0] pointer, input [7:0] byte0, input [7:0] byte1);
        integer previous_starts, previous_stops;
        real capture_begin, capture_end;
        previous_starts=starts;
        previous_stops=stops;
        capture_no=capture_no+1;
        sensor_kind=kind;
        capture_label=label;
        sample_value=(kind==3) ? {byte0,byte1} : {8'h00,byte0};
        expected_byte0=byte0; expected_byte1=byte1;
        byte_number=0; bit_number=0;
        capture_begin=$realtime;
        $display("CAPTURE %0d %0s: S 84 A %02h A Sr 85 A %02h A %02h N P",
                 capture_no,label,pointer,byte0,byte1);
        fork
            begin
                @(negedge clk); reg_addr=pointer; start=1;
                @(negedge clk); start=0;
                wait(done); #1;
                // rx_frame packs the first received byte in the LOW byte.
                if(busy || nack_error || timeout_error || rx_frame!=={byte1,byte0} || rx_data!==byte1)
                    $fatal(1,"Capture %0d completion or receive frame incorrect",capture_no);
                @(posedge clk); #1;
                if(done) $fatal(1,"Completion must be one clock wide");
            end
            begin
                start_condition(0);
                check_byte(1,"ADDR_W",8'h84,1);
                check_byte(2,"REGISTER",pointer,1);
                start_condition(1);
                check_byte(3,"ADDR_R",8'h85,1);
                check_byte(4,"DATA_0",byte0,1);
                check_byte(5,"DATA_1",byte1,0);
                do @(posedge sda); while(scl!==1'b1);
                bus_stage="STOP";
                $fwrite(events_file,"%0d,%0.3f,STOP\n",capture_no,$realtime);
            end
        join
        capture_end=$realtime;
        if(starts!=previous_starts+2 || stops!=previous_stops+1 || reg_ptr!==(pointer+8'd2))
            $fatal(1,"Capture %0d START/repeated START/STOP/pointer incorrect",capture_no);
        $fwrite(captures_file,"%0d,%0s,%0d,%0.3f,%0.3f,%02h,%02h,%02h,%0d,%0d\n",
                capture_no,label,kind,capture_begin,capture_end,pointer,byte0,byte1,sample_value,
                (kind==3) ? 0 : byte1);
        checks=checks+1;
        bus_stage="IDLE"; byte_number=0; bit_number=0;
        #200_000;
    endtask

    initial begin
        if(SENSOR_SELECT<0 || SENSOR_SELECT>3) $fatal(1,"SENSOR_SELECT must be 0..3");
        edges_file=$fopen($sformatf("%0s_edges.csv",OUTPUT_PREFIX),"w");
        bytes_file=$fopen($sformatf("%0s_bytes.csv",OUTPUT_PREFIX),"w");
        captures_file=$fopen($sformatf("%0s_captures.csv",OUTPUT_PREFIX),"w");
        events_file=$fopen($sformatf("%0s_events.csv",OUTPUT_PREFIX),"w");
        if(!edges_file || !bytes_file || !captures_file || !events_file) $fatal(1,"Cannot open scope capture files");
        $fwrite(edges_file,"time_ns,scl,sda\n");
        $fwrite(edges_file,"%0.3f,%b,%b\n",$realtime,scl,sda);
        $fwrite(bytes_file,"capture,index,phase,start_ns,end_ns,hex,ack\n");
        $fwrite(captures_file,"capture,label,sensor,start_ns,end_ns,register,byte0,byte1,value,fraction\n");
        $fwrite(events_file,"capture,time_ns,event\n");
        // Vivado 2020.2 requires a literal filename for this system task.
        case(SENSOR_SELECT)
            1: $dumpfile("i2c_scope_temp.vcd");
            2: $dumpfile("i2c_scope_humidity.vcd");
            3: $dumpfile("i2c_scope_distance.vcd");
            default: $dumpfile("i2c_scope.vcd");
        endcase
        $dumpvars(0,scl,sda,reset,start,reg_addr,rx_frame,busy,done,
                  capture_no,capture_label,bus_stage,byte_label,decoded_byte,byte_number,bit_number,
                  expected_byte0,expected_byte1,nack_error,timeout_error);
        #20_000; reset=0;
        #30_000;
        if(SENSOR_SELECT==0 || SENSOR_SELECT==2) capture_read(2,"HUM_36PCT",8'h01,8'h24,8'h00);
        if(SENSOR_SELECT==0 || SENSOR_SELECT==1) capture_read(1,"TEMP_28.4C",8'h03,8'h1c,8'h04);
        if(SENSOR_SELECT==0 || SENSOR_SELECT==3) capture_read(3,"DIST_3CM",8'h05,8'h00,8'h03);
        if(checks!=((SENSOR_SELECT==0) ? 3 : 1)) $fatal(1,"Missing scope captures");
        $fclose(edges_file); edges_file=0;
        $fclose(bytes_file); $fclose(captures_file); $fclose(events_file);
        $display("PASS: %m: %0d sensor captures, 100 kHz, two-byte reads, actual Slave, ACK/NACK, repeated START and STOP",checks);
        $finish;
    end
    initial begin #10_000_000; $fatal(1,"Scope test watchdog timeout"); end
endmodule

// Explicit uninstantiated top so Vivado lists the all-sensor demo beside the
// individual sensor tops, rather than only under their shared scope hierarchy.
module tb_i2c_scope_all;
    tb_i2c_scope #(.SENSOR_SELECT(0), .OUTPUT_PREFIX("i2c_scope")) scope();
endmodule

module tb_i2c_scope_temp;
    tb_i2c_scope #(.SENSOR_SELECT(1), .OUTPUT_PREFIX("i2c_scope_temp")) scope();
endmodule
module tb_i2c_scope_humidity;
    tb_i2c_scope #(.SENSOR_SELECT(2), .OUTPUT_PREFIX("i2c_scope_humidity")) scope();
endmodule
module tb_i2c_scope_distance;
    tb_i2c_scope #(.SENSOR_SELECT(3), .OUTPUT_PREFIX("i2c_scope_distance")) scope();
endmodule
