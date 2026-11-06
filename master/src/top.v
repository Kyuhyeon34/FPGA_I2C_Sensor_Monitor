`timescale 1ns / 1ps

module top #(
    parameter integer CLOCK_HZ = 100_000_000,
    parameter integer I2C_HZ = 100_000,
    parameter [6:0] SLAVE_ADDR = 7'h42,
    parameter integer BAUD = 9600,
    parameter integer DEBOUNCE_CYCLES = CLOCK_HZ / 100,
    parameter integer OLED_ENABLE = 1,
    parameter integer OLED_POWERUP_CYCLES = CLOCK_HZ / 10,
    parameter integer OLED_RETRY_CYCLES = CLOCK_HZ / 2,
    parameter integer OLED_ANIMATION_CYCLES = CLOCK_HZ / 2,
    parameter integer POLL_INTERVAL_CYCLES = CLOCK_HZ / 10
)(
    input clk,
    input reset,                 // SW15: high resets, low runs.
    input [1:0] btn,             // Center: read all sensors. Up: toggle FND mode.
    input [7:0] sw,              // Reserved; retained for the board pin constraints.
    inout sda,                   // JA1
    inout scl,                   // JA2
    output [15:0] led,
    output [7:0] seg,
    output [3:0] an,
    output RsTx
);
    (* ASYNC_REG = "TRUE" *) reg [3:0] reset_pipe = 4'b1111;
    wire rst = reset_pipe[3];
    always @(posedge clk or posedge reset) begin
        if (reset) reset_pipe <= 4'b1111;
        else reset_pipe <= {reset_pipe[2:0], 1'b0};
    end
    wire read_pulse, mode_pulse;
    button_pulse #(.STABLE_CYCLES(DEBOUNCE_CYCLES)) u_read_button
        (.clk(clk), .reset(rst), .button(btn[0]), .pulse(read_pulse));
    button_pulse #(.STABLE_CYCLES(DEBOUNCE_CYCLES)) u_mode_button
        (.clk(clk), .reset(rst), .button(btn[1]), .pulse(mode_pulse));
    reg distance_mode;
    always @(posedge clk or posedge rst) begin
        if (rst) distance_mode <= 0;
        else if (mode_pulse) distance_mode <= ~distance_mode;
    end

    wire [7:0] rx_data;
    wire busy, done, nack_error, timeout_error;
    reg master_start, reading_frame;
    localparam [1:0] OWNER_NONE=0, OWNER_SENSOR=1, OWNER_OLED=2;
    reg [1:0] bus_owner;
    reg sensor_pending, sensor_nack;
    reg [7:0] master_register;
    reg [6:0] master_address;
    reg master_read;
    reg [7:0] tx_data, humidity, temperature;
    reg [15:0] distance_cm;
    wire [63:0] frame_data;
    reg [15:0] display_bcd;
    reg [15:0] distance_display_bcd;
    wire [15:0] fnd_bcd = distance_mode ? distance_display_bcd : display_bcd;
    wire [3:0] fnd_dots = distance_mode ? 4'b0000 : 4'b0100;
    reg pass, fail;

    // Actual i2c_regs map: 00=ID, 01=H integer, 02=H decimal,
    // 03=T integer, 04=T decimal, 05/06=distance H/L, 07=status.
    // DHT11 values may be used only when status bit 0 says checksum OK.
    wire [7:0] completed_humidity = frame_data[15:8];
    wire [7:0] completed_temperature = frame_data[31:24];
    wire [7:0] completed_temperature_decimal = frame_data[39:32];
    wire [15:0] completed_distance = {frame_data[47:40], frame_data[55:48]};
    wire id_valid = frame_data[7:0] == 8'ha5;
    wire frame_valid = id_valid && frame_data[56];
    wire distance_valid = id_valid && frame_data[57];

    reg [5:0] print_index;
    reg printing, uart_start, print_valid;
    reg [7:0] uart_data, print_humidity, print_temperature;
    reg [7:0] print_temperature_decimal;
    reg print_distance_valid, print_id_valid;
    wire [19:0] converted_distance;
    wire distance_converted;
    reg [63:0] print_data;
    reg [1:0] print_state;
    wire uart_busy;
    wire bus_available = bus_owner==OWNER_NONE && !busy && !done && !master_start;
    wire can_queue_sensor = !sensor_pending && bus_owner!=OWNER_SENSOR && !printing;
    // A due poll waits for the current sensor/UART transaction to finish.
    // Saturating the timer coalesces missed polls instead of building a backlog.
    localparam integer POLL_TICKS = (POLL_INTERVAL_CYCLES < 1) ? 1 : POLL_INTERVAL_CYCLES;
    localparam integer POLL_WIDTH = (POLL_TICKS < 2) ? 1 : $clog2(POLL_TICKS);
    reg [POLL_WIDTH-1:0] poll_count;
    wire poll_due = (POLL_INTERVAL_CYCLES > 0) && (poll_count == POLL_TICKS-1);
    wire oled_request, oled_ready, oled_error;
    wire [7:0] oled_control, oled_data;
    reg oled_accepted, oled_transfer_done, oled_transfer_error;
    wire completed_read = done && bus_owner==OWNER_SENSOR &&
                          !nack_error && !timeout_error;
    // Sensor values/flags are captured with print_data, then used only after
    // the 16-cycle conversion completes. New reads wait for UART completion.
    binary_to_bcd16 u_distance_bcd (
        .clk(clk), .reset(rst), .start(completed_read), .binary(completed_distance),
        .bcd(converted_distance), .done(distance_converted)
    );
    wire oled_update = distance_converted && print_id_valid;
    generate if(OLED_ENABLE) begin : g_oled
        ssd1306_oled #(.POWERUP_CYCLES(OLED_POWERUP_CYCLES), .RETRY_CYCLES(OLED_RETRY_CYCLES),
                      .ANIMATION_CYCLES(OLED_ANIMATION_CYCLES)) u_display (
            .clk(clk), .reset(rst), .update(oled_update),
            .humidity(print_humidity), .temperature(print_temperature),
            .temperature_decimal(print_temperature_decimal),
            .humidity_valid(print_valid), .distance_bcd(converted_distance),
            .distance_valid(print_distance_valid),
            .request(oled_request), .control(oled_control), .data(oled_data),
            .accepted(oled_accepted), .transfer_done(oled_transfer_done),
            .transfer_error(oled_transfer_error), .ready(oled_ready), .error(oled_error)
        );
    end else begin : g_no_oled
        assign oled_request=0;
        assign oled_ready=0;
        assign oled_error=0;
        assign oled_control=0;
        assign oled_data=0;
    end endgenerate

    i2c_master #(.CLOCK_HZ(CLOCK_HZ), .I2C_HZ(I2C_HZ),
                 .REGISTER_MODE(1), .READ_BYTES(8)) u_master (
        .clk(clk), .reset(rst), .start(master_start), .slave_addr(master_address),
        .read_not_write(master_read), .tx_data(tx_data), .rx_data(rx_data),
        .reg_addr(master_register), .rx_frame(frame_data),
        .busy(busy), .done(done), .nack_error(nack_error),
        .timeout_error(timeout_error), .scl(scl), .sda(sda)
    );
    assign led = {pass, fail, sensor_nack, (busy || reading_frame), oled_error, oled_ready, 2'b00, humidity};
    // HH.TT or four-digit distance in cm, selected locally with BTNU.
    fnd_display #(.CLOCK_HZ(CLOCK_HZ)) u_display (
        .clk(clk), .reset(rst), .bcd_data(fnd_bcd), .dot_en(fnd_dots),
        .seg(seg), .an(an)
    );
    uart_tx #(.CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD)) u_uart (
        .clk(clk), .reset(rst), .start(uart_start), .data(uart_data),
        .tx(RsTx), .busy(uart_busy)
    );
    function [7:0] hex_ascii;
        input [3:0] nibble;
        begin hex_ascii = (nibble < 10) ? 8'h30 + nibble : 8'h41 + nibble - 10; end
    endfunction
    function [7:0] line_character;
        input [5:0] index;
        reg [5:0] offset;
        reg [7:0] raw_byte;
        begin
            offset = index - 25;
            raw_byte = print_data[(offset / 3) * 8 +: 8];
            if (index >= 25 && index < 48) begin
                case (offset % 3)
                    0: line_character = hex_ascii(raw_byte[7:4]);
                    1: line_character = hex_ascii(raw_byte[3:0]);
                    default: line_character = " ";
                endcase
            end else case (index)
                0: line_character = "H";
                1, 7, 13, 24: line_character = "=";
                2: line_character = print_valid ? 8'h30 + print_humidity / 100 : "?";
                3: line_character = print_valid ? 8'h30 + (print_humidity / 10) % 10 : "?";
                4: line_character = print_valid ? 8'h30 + print_humidity % 10 : "?";
                5, 11, 21: line_character = " ";
                6: line_character = "T";
                8: line_character = print_valid ? 8'h30 + print_temperature / 100 : "?";
                9: line_character = print_valid ? 8'h30 + (print_temperature / 10) % 10 : "?";
                10: line_character = print_valid ? 8'h30 + print_temperature % 10 : "?";
                12: line_character = "D";
                14: line_character = print_distance_valid ? {4'h3,converted_distance[19:16]} : "?";
                15: line_character = print_distance_valid ? {4'h3,converted_distance[15:12]} : "?";
                16: line_character = print_distance_valid ? {4'h3,converted_distance[11:8]} : "?";
                17: line_character = print_distance_valid ? {4'h3,converted_distance[7:4]} : "?";
                18: line_character = print_distance_valid ? {4'h3,converted_distance[3:0]} : "?";
                19: line_character = "c";
                20: line_character = "m";
                22: line_character = "R";
                23: line_character = "X";
                48: line_character = 8'h0d;
                49: line_character = 8'h0a;
                default: line_character = " ";
            endcase
        end
    endfunction
    function [15:0] sensor_bcd;
        input [7:0] h, t;
        reg [3:0] h_tens, h_ones, t_tens, t_ones;
        reg [7:0] shown_h, shown_t;
        begin
            // Match the Slave FND's saturation at 99; UART keeps the full byte.
            shown_h = (h > 99) ? 8'd99 : h;
            shown_t = (t > 99) ? 8'd99 : t;
            h_tens = shown_h / 10; h_ones = shown_h % 10;
            t_tens = shown_t / 10; t_ones = shown_t % 10;
            sensor_bcd = {h_tens, h_ones, t_tens, t_ones};
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            master_start <= 0;
            reading_frame <= 0;
            bus_owner <= OWNER_NONE;
            sensor_pending <= 0;
            poll_count <= POLL_TICKS-1; // First read immediately after reset.
            sensor_nack <= 0;
            master_register <= 0;
            master_address <= SLAVE_ADDR;
            master_read <= 0;
            oled_accepted <= 0;
            oled_transfer_done <= 0;
            oled_transfer_error <= 0;
            tx_data <= 0;
            humidity <= 0;
            temperature <= 0;
            distance_cm <= 0;
            display_bcd <= 0;
            distance_display_bcd <= 0;
            pass <= 0;
            fail <= 0;
            printing <= 0;
            print_index <= 0;
            print_data <= 0;
            print_humidity <= 0;
            print_temperature <= 0;
            print_temperature_decimal <= 0;
            print_distance_valid <= 0;
            print_id_valid <= 0;
            print_valid <= 0;
            print_state <= 0;
            uart_start <= 0;
            uart_data <= 0;
        end else begin
            master_start <= 0;
            uart_start <= 0;
            oled_accepted <= 0;
            oled_transfer_done <= 0;
            if (POLL_INTERVAL_CYCLES > 0 && !poll_due)
                poll_count <= poll_count + 1'b1;
            // Retain only a validated distance after the shared BCD conversion.
            if (distance_converted && print_distance_valid)
                distance_display_bcd <= (converted_distance[19:16] != 0) ?
                                        16'h9999 : converted_distance[15:0];
            // Queue one human request during an OLED byte transfer. It wins at
            // the next transaction boundary; sensor bursts are never interrupted.
            if (can_queue_sensor && (read_pulse || poll_due)) begin
                sensor_pending <= 1;
            end
            if (bus_available) begin
                if (sensor_pending) begin
                    sensor_pending <= 0;
                    master_read <= 1;
                    master_address <= SLAVE_ADDR;
                    master_register <= 8'h00;
                    tx_data <= 0;
                    master_start <= 1;
                    bus_owner <= OWNER_SENSOR;
                    reading_frame <= 1;
                    poll_count <= 0;
                    pass <= 0;
                    fail <= 0;
                    sensor_nack <= 0;
                end else if (oled_request) begin
                    master_read <= 0;
                    master_address <= 7'h3c;
                    master_register <= oled_control;
                    tx_data <= oled_data;
                    master_start <= 1;
                    bus_owner <= OWNER_OLED;
                    oled_accepted <= 1;
                end
            end
            if (done) begin
                bus_owner <= OWNER_NONE;
                if (bus_owner==OWNER_OLED) begin
                    oled_transfer_done <= 1;
                    oled_transfer_error <= nack_error || timeout_error;
                end else if (bus_owner==OWNER_SENSOR) begin
                sensor_nack <= nack_error;
                if (nack_error || timeout_error) begin
                    // Abort a partial frame without changing displayed values.
                    reading_frame <= 0;
                    pass <= 0;
                    fail <= 1;
                end else begin
                    reading_frame <= 0;
                    pass <= frame_valid;
                    fail <= !frame_valid;
                    if (frame_valid) begin
                        humidity <= completed_humidity;
                        temperature <= completed_temperature;
                        display_bcd <= sensor_bcd(completed_humidity, completed_temperature);
                    end
                    if (distance_valid) distance_cm <= completed_distance;
                    print_data <= frame_data;
                    print_humidity <= completed_humidity;
                    print_temperature <= completed_temperature;
                    print_temperature_decimal <= completed_temperature_decimal;
                    print_distance_valid <= distance_valid;
                    print_id_valid <= id_valid;
                    print_valid <= frame_valid;
                    printing <= 1;
                    print_index <= 0;
                    print_state <= 3;
                end
                end
            end
            if (printing) begin
                case (print_state)
                    3: if (distance_converted) print_state <= 0;
                    0: if (!uart_busy) begin
                        uart_data <= line_character(print_index);
                        uart_start <= 1;
                        print_state <= 1;
                    end
                    1: if (uart_busy) print_state <= 2;
                    2: if (!uart_busy) begin
                        if (print_index == 49) printing <= 0;
                        else print_index <= print_index + 1'b1;
                        print_state <= 0;
                    end
                    default: print_state <= 0;
                endcase
            end
        end
    end
endmodule
