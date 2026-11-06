`timescale 1ns / 1ps

module tb_i2c_master;
    reg clk=0, reset=1, start=0, read_not_write=0;
    reg [6:0] slave_addr=7'h42;
    reg [7:0] tx_data=0;
    reg [7:0] reg_addr=0;
    wire [7:0] rx_data;
    wire [7:0] rx_frame;
    wire busy, done, nack_error, timeout_error;
    tri1 scl, sda;
    reg slave_scl_low=0, slave_sda_low=0;
    assign scl = slave_scl_low ? 1'b0 : 1'bz;
    assign sda = slave_sda_low ? 1'b0 : 1'bz;
    always #5 clk=~clk;
    // Use the actual board's 100 MHz / 100 kHz timing.
    i2c_master #(.CLOCK_HZ(100_000_000), .I2C_HZ(100_000),
                 .TIMEOUT_CYCLES(2000)) dut (.*);
    integer tests=0, starts=0, stops=0;
    reg timing_enabled=0;
    realtime last_rise=0, last_fall=0;
    reg [7:0] observed;
    always @(posedge scl) begin
        if(timing_enabled && last_fall > 0 && $realtime-last_fall < 4700)
            $fatal(1,"Standard-mode SCL low interval too short");
        last_rise=$realtime;
    end
    always @(negedge scl) begin
        if(timing_enabled && last_rise > 0 && $realtime-last_rise < 4000)
            $fatal(1,"Standard-mode SCL high interval too short");
        last_fall=$realtime;
    end
    always @(negedge sda) if (scl === 1'b1 && !reset) starts=starts+1;
    always @(posedge sda) if (scl === 1'b1 && !reset) stops=stops+1;

    task launch(input bit rd, input [7:0] value);
        @(negedge clk);
        read_not_write=rd; tx_data=value; start=1;
        @(negedge clk); start=0;
    endtask
    task wait_start;
        @(negedge sda);
        if (scl !== 1'b1) $fatal(1,"START missing");
    endtask
    task wait_stop;
        do @(posedge sda); while (scl !== 1'b1);
    endtask
    task receive_byte(output reg [7:0] value);
        integer i;
        for(i=7;i>=0;i=i-1) begin
            @(posedge scl); #1; value[i]=sda;
        end
    endtask
    task slave_ack(input bit ack, input bit stretch);
        @(negedge scl); slave_sda_low=ack;
        if(stretch) begin
            slave_scl_low=1;
            #3000;
            slave_scl_low=0;
        end
        @(posedge scl);
        @(negedge scl); slave_sda_low=0;
    endtask
    task send_byte(input [7:0] value);
        integer i;
        // Called at the falling edge completing the address ACK.
        for(i=7;i>=0;i=i-1) begin
            slave_sda_low=!value[i];
            @(posedge scl);
            @(negedge scl);
        end
        slave_sda_low=0;
        @(posedge scl); #1;
        if(sda !== 1'b1) $fatal(1,"Master must NACK the final received byte");
        @(negedge scl);
    endtask
    task completion(input bit nack, input bit timeout_expected);
        wait(done); #1;
        if(busy || nack_error !== nack || timeout_error !== timeout_expected)
            $fatal(1,"Bad completion busy=%b nack=%b timeout=%b",busy,nack_error,timeout_error);
        @(posedge clk); #1;
        if(done) $fatal(1,"done must be one clock wide");
        tests=tests+1;
    endtask
    task test_write(input [7:0] value, input bit stretch);
        integer old_starts, old_stops;
        old_starts=starts; old_stops=stops;
        timing_enabled=1;
        fork
            begin launch(0,value); completion(0,0); end
            begin
                wait_start(); receive_byte(observed);
                if(observed !== 8'h84) $fatal(1,"Write address/RW is wrong");
                slave_ack(1,stretch);
                receive_byte(observed);
                if(observed !== value) $fatal(1,"Write data order is wrong");
                slave_ack(1,0); wait_stop();
            end
        join
        if(starts!=old_starts+1 || stops!=old_stops+1)
            $fatal(1,"Unexpected START/STOP during write");
        timing_enabled=0;
    endtask
    task test_read(input [7:0] value);
        integer old_starts, old_stops;
        old_starts=starts; old_stops=stops;
        timing_enabled=1;
        fork
            begin
                launch(1,0); completion(0,0);
                if(rx_data !== value) $fatal(1,"Read data mismatch: %h expected %h",rx_data,value);
            end
            begin
                wait_start(); receive_byte(observed);
                if(observed !== 8'h85) $fatal(1,"Read address/RW is wrong");
                slave_ack(1,0); send_byte(value); wait_stop();
            end
        join
        if(starts!=old_starts+1 || stops!=old_stops+1)
            $fatal(1,"Unexpected START/STOP during read");
        timing_enabled=0;
    endtask

    initial begin
        #100; @(negedge clk); reset=0;
        test_write(8'ha5,0);
        test_write(8'h00,0);
        test_write(8'hff,0);
        test_write(8'h5a,1);
        test_read(8'h00);
        test_read(8'hff);
        test_read(8'haa);
        test_read(8'h55);
        // An address NACK must terminate with STOP and no data clocks.
        fork
            begin launch(1,0); completion(1,0); end
            begin wait_start(); receive_byte(observed); slave_ack(0,0); wait_stop(); end
        join
        // A data NACK has the same error result.
        fork
            begin launch(0,8'h12); completion(1,0); end
            begin
                wait_start(); receive_byte(observed); slave_ack(1,0);
                receive_byte(observed); slave_ack(0,0); wait_stop();
            end
        join
        // New request during busy must not change the latched transaction.
        fork
            begin
                launch(0,8'hc3);
                repeat(100) @(negedge clk);
                launch(1,8'hff);
                completion(0,0);
            end
            begin
                wait_start(); receive_byte(observed); slave_ack(1,0);
                receive_byte(observed);
                if(observed !== 8'hc3) $fatal(1,"Busy request overwrote data");
                slave_ack(1,0); wait_stop();
            end
        join
        // Idle bus held low: complete with timeout, never hang.
        slave_sda_low=1; repeat(4) @(negedge clk);
        launch(1,0); completion(0,1);
        if(dut.scl_low || dut.sda_low) $fatal(1,"Timeout did not release bus");
        slave_sda_low=0; repeat(4) @(negedge clk);
        slave_scl_low=1; repeat(4) @(negedge clk);
        launch(1,0); completion(0,1);
        slave_scl_low=0; repeat(4) @(negedge clk);
        // Timeout during a transaction, after the address was ACKed.
        fork
            begin launch(1,0); completion(0,1); end
            begin
                wait_start(); receive_byte(observed);
                @(negedge scl); slave_sda_low=1; slave_scl_low=1;
                wait(done); slave_sda_low=0; slave_scl_low=0;
            end
        join
        repeat(4) @(negedge clk);
        test_read(8'h96); // Errors clear on the next accepted request.
        // Reset in the middle of a transaction releases both pins.
        launch(0,8'h22); wait_start(); @(negedge scl);
        reset=1; #1;
        if(busy || dut.scl_low || dut.sda_low) $fatal(1,"Reset failed to release bus");
        repeat(4) @(negedge clk); reset=0;
        test_write(8'h81,0);
        $display("PASS: tb_i2c_master: %0d transactions plus reset recovery",tests);
        $finish;
    end
    initial begin #5_000_000; $fatal(1,"Testbench watchdog timeout"); end
endmodule
