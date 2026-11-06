`timescale 1ns / 1ps
//==============================================================================
// tb_sensors : behavioral DHT11 / HC-SR04 models vs dht11_ctrl / hcsr04_ctrl
//==============================================================================
module tb_sensors;

    reg clk = 0, reset = 1;
    always #5 clk = ~clk;

    integer errors = 0;

    //=========================================================== DHT11
    wire dht;
    reg  s_low = 0;                      // sensor pulls low
    assign dht = s_low ? 1'b0 : 1'bz;
    pullup(dht);

    wire [7:0] hum_int, hum_dec, tmp_int, tmp_dec;
    wire       dht_valid, dht_done;

    dht11_ctrl #(.PERIOD_US(100)) u_dht (
        .clk(clk), .reset(reset), .dht11_data(dht),
        .hum_int(hum_int), .hum_dec(hum_dec), .tmp_int(tmp_int), .tmp_dec(tmp_dec),
        .valid(dht_valid), .done_toggle(dht_done)
    );

    // DHT11 model : answers one frame per host start
    reg [39:0] frame;
    task dht_reply(input [39:0] f);
        integer i; time t0;
        begin
            @(negedge dht); t0 = $time;
            @(posedge dht);
            if ($time - t0 < 18_000_000) $display("[WARN] host start low too short");
            #30_000;  s_low = 1; #80_000; s_low = 0; #80_000;
            for (i = 39; i >= 0; i = i - 1) begin
                s_low = 1; #50_000; s_low = 0;
                if (f[i]) #70_000; else #27_000;
            end
            s_low = 1; #50_000; s_low = 0;
        end
    endtask

    //=========================================================== HC-SR04
    wire        trig;
    reg         echo = 0;
    wire [15:0] dist_cm;
    wire        dist_valid;

    hcsr04_ctrl #(.PERIOD_US(100)) u_us (
        .clk(clk), .reset(reset), .trig(trig), .echo(echo),
        .dist_cm(dist_cm), .valid(dist_valid)
    );

    initial begin : us_model                // 100cm object : 5800us echo
        forever begin
            @(negedge trig);
            #200_000; echo = 1; #5_800_000; echo = 0;
        end
    end

    //=========================================================== sequence
    initial begin
        #200 reset = 0;

        // frame 1 : hum 55.0, tmp 24.3, checksum OK
        frame = {8'd55, 8'd0, 8'd24, 8'd3, 8'd55 + 8'd0 + 8'd24 + 8'd3};
        fork dht_reply(frame); @(dht_done); join
        #100;
        if (dht_valid && hum_int == 55 && hum_dec == 0 && tmp_int == 24 && tmp_dec == 3)
             $display("[PASS] DHT11 frame1 : H=%0d.%0d T=%0d.%0d", hum_int, hum_dec, tmp_int, tmp_dec);
        else begin $display("[FAIL] DHT11 frame1 : valid=%b H=%0d T=%0d", dht_valid, hum_int, tmp_int); errors = errors + 1; end

        // frame 2 : bad checksum -> valid=0, previous values kept
        frame = {8'd60, 8'd0, 8'd30, 8'd0, 8'hFF};
        fork dht_reply(frame); @(dht_done); join
        #100;
        if (!dht_valid && hum_int == 55 && tmp_int == 24)
             $display("[PASS] DHT11 frame2 bad checksum rejected, values kept");
        else begin $display("[FAIL] DHT11 frame2 : valid=%b H=%0d", dht_valid, hum_int); errors = errors + 1; end

        // HC-SR04 (runs in parallel since reset)
        if (dist_valid && dist_cm == 100)
             $display("[PASS] HC-SR04 : %0d cm", dist_cm);
        else begin $display("[FAIL] HC-SR04 : valid=%b dist=%0d", dist_valid, dist_cm); errors = errors + 1; end

        if (errors == 0) $display("==== ALL TESTS PASSED ====");
        else             $display("==== %0d TEST(S) FAILED ====", errors);
        $finish;
    end

    initial begin #200_000_000; $display("TIMEOUT"); $finish; end

endmodule
