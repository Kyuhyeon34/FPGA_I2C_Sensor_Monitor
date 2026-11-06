`timescale 1ns / 1ps

// Single-master, 7-bit address. Optional indexed reads with repeated START,
// READ_BYTES-byte receive burst, and register-address + one-byte writes.
// All logic uses clk. SCL/SDA only drive zero; external pull-ups supply one.
module i2c_master #(
    parameter integer CLOCK_HZ = 100_000_000,
    parameter integer I2C_HZ = 100_000,
    parameter integer TIMEOUT_CYCLES = CLOCK_HZ / 100,
    parameter integer REGISTER_MODE = 0,
    parameter integer READ_BYTES = 1
)(
    input clk,
    input reset,
    input start,                  // One clk pulse; ignored while busy.
    input [6:0] slave_addr,
    input read_not_write,
    input [7:0] tx_data,
    input [7:0] reg_addr,
    output reg [7:0] rx_data,
    output reg [READ_BYTES*8-1:0] rx_frame, // First byte in bits [7:0].
    output reg busy,
    output reg done,              // One clk pulse, including failed transfers.
    output reg nack_error,        // Sticky until next accepted start/reset.
    output reg timeout_error,
    inout scl,
    inout sda
);
    localparam integer QUARTER = CLOCK_HZ / (4 * I2C_HZ);
    localparam integer CW = (QUARTER < 2) ? 1 : $clog2(QUARTER);
    localparam integer TW = (TIMEOUT_CYCLES < 2) ? 1 : $clog2(TIMEOUT_CYCLES);
    localparam integer RW = (READ_BYTES < 2) ? 1 : $clog2(READ_BYTES);
    localparam [3:0] IDLE=0, BUS_FREE=1, START_HOLD=2, START_LOW=3,
                     SEND=4, SLAVE_ACK=5, RECEIVE=6, MASTER_REPLY=7,
                     STOP_LOW=8, STOP_HIGH=9, STOP_RELEASE=10, FINISH=11,
                     RESTART_LOW=12, RESTART_HIGH=13;
    localparam [1:0] ADDRESS=0, REG_POINTER=1, WRITE_DATA=2, READ_ADDRESS=3;

    reg [3:0] state;
    reg [1:0] phase;
    reg [2:0] bit_index;
    reg [7:0] shift_data, write_data, register_address, read_address;
    reg read_command;
    reg [1:0] byte_kind;
    reg [RW-1:0] read_index;
    reg scl_low, sda_low;
    reg [CW-1:0] divider;
    reg [TW-1:0] wait_count;
    (* ASYNC_REG = "TRUE" *) reg [1:0] scl_sync, sda_sync;
    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;

    // Wait for the actual bus, including a slave stretching SCL.
    wire waiting = (!scl_low && !scl_sync[1]) ||
                   (state == BUS_FREE && !sda_sync[1]);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            scl_sync <= 2'b11;
            sda_sync <= 2'b11;
        end else begin
            scl_sync <= {scl_sync[0], scl};
            sda_sync <= {sda_sync[0], sda};
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            phase <= 0;
            bit_index <= 7;
            shift_data <= 0;
            write_data <= 0;
            read_command <= 0;
            register_address <= 0;
            read_address <= 0;
            byte_kind <= ADDRESS;
            read_index <= 0;
            scl_low <= 0;
            sda_low <= 0;
            divider <= 0;
            wait_count <= 0;
            rx_data <= 0;
            rx_frame <= 0;
            busy <= 0;
            done <= 0;
            nack_error <= 0;
            timeout_error <= 0;
        end else begin
            done <= 0;
            if (state == IDLE) begin
                divider <= 0;
                wait_count <= 0;
                if (start) begin
                    shift_data <= {slave_addr, REGISTER_MODE ? 1'b0 : read_not_write};
                    write_data <= tx_data;
                    register_address <= reg_addr;
                    read_address <= {slave_addr, 1'b1};
                    read_command <= read_not_write;
                    byte_kind <= ADDRESS;
                    read_index <= 0;
                    rx_frame <= 0;
                    nack_error <= 0;
                    timeout_error <= 0;
                    busy <= 1;
                    phase <= 0;
                    state <= BUS_FREE;
                end
            end else if (waiting) begin
                divider <= 0;
                if (state == BUS_FREE) phase <= 0;
                if (wait_count == TIMEOUT_CYCLES - 1) begin
                    // A stuck bus cannot guarantee STOP. Release both pins.
                    scl_low <= 0;
                    sda_low <= 0;
                    timeout_error <= 1;
                    busy <= 0;
                    done <= 1;
                    state <= IDLE;
                    wait_count <= 0;
                end else wait_count <= wait_count + 1'b1;
            end else begin
                wait_count <= 0;
                if (divider == QUARTER - 1) begin
                    divider <= 0;
                    case (state)
                        BUS_FREE: begin
                            // Two quarters satisfy Standard-mode tBUF (4.7 us).
                            if (phase == 1) begin
                                sda_low <= 1;
                                phase <= 0;
                                state <= START_HOLD;
                            end else phase <= phase + 1'b1;
                        end
                        START_HOLD: begin
                            if (phase == 1) begin
                                scl_low <= 1;
                                phase <= 0;
                                state <= START_LOW;
                            end else phase <= phase + 1'b1;
                        end
                        START_LOW: begin
                            phase <= 0;
                            bit_index <= 7;
                            state <= SEND;
                        end
                        RESTART_LOW: begin
                            sda_low <= 0;
                            if (phase == 1) begin
                                scl_low <= 0;
                                phase <= 0;
                                state <= RESTART_HIGH;
                            end else phase <= phase + 1'b1;
                        end
                        RESTART_HIGH: begin
                            if (phase == 1) begin
                                sda_low <= 1;
                                phase <= 0;
                                state <= START_HOLD;
                            end else phase <= phase + 1'b1;
                        end
                        SEND, SLAVE_ACK, RECEIVE, MASTER_REPLY: begin
                            phase <= phase + 1'b1;
                            case (phase)
                                0: begin
                                    if (state == SEND)
                                        sda_low <= !shift_data[bit_index];
                                    else if (state == MASTER_REPLY)
                                        sda_low <= (read_index != READ_BYTES - 1);
                                    else sda_low <= 0;
                                end
                                1: scl_low <= 0;
                                2: begin
                                    if (state == SLAVE_ACK && sda_sync[1])
                                        nack_error <= 1;
                                    if (state == RECEIVE)
                                        shift_data[bit_index] <= sda_sync[1];
                                end
                                3: begin
                                    scl_low <= 1;
                                    case (state)
                                        SEND: begin
                                            if (bit_index == 0) state <= SLAVE_ACK;
                                            else bit_index <= bit_index - 1'b1;
                                        end
                                        SLAVE_ACK: begin
                                            bit_index <= 7;
                                            if (nack_error) state <= STOP_LOW;
                                            else case (byte_kind)
                                                ADDRESS: begin
                                                    if (REGISTER_MODE) begin
                                                        shift_data <= register_address;
                                                        byte_kind <= REG_POINTER;
                                                        state <= SEND;
                                                    end else if (read_command) state <= RECEIVE;
                                                    else begin
                                                        shift_data <= write_data;
                                                        byte_kind <= WRITE_DATA;
                                                        state <= SEND;
                                                    end
                                                end
                                                REG_POINTER: begin
                                                    if (read_command) begin
                                                        shift_data <= read_address;
                                                        byte_kind <= READ_ADDRESS;
                                                        state <= RESTART_LOW;
                                                    end else begin
                                                        shift_data <= write_data;
                                                        byte_kind <= WRITE_DATA;
                                                        state <= SEND;
                                                    end
                                                end
                                                READ_ADDRESS: state <= RECEIVE;
                                                default: state <= STOP_LOW;
                                            endcase
                                        end
                                        RECEIVE: begin
                                            if (bit_index == 0) begin
                                                rx_data <= shift_data;
                                                rx_frame[read_index * 8 +: 8] <= shift_data;
                                                state <= MASTER_REPLY;
                                            end else bit_index <= bit_index - 1'b1;
                                        end
                                        // ACK intermediate bytes, NACK the final byte.
                                        MASTER_REPLY: begin
                                            if (read_index == READ_BYTES - 1) state <= STOP_LOW;
                                            else begin
                                                read_index <= read_index + 1'b1;
                                                bit_index <= 7;
                                                state <= RECEIVE;
                                            end
                                        end
                                    endcase
                                end
                            endcase
                        end
                        STOP_LOW: begin
                            sda_low <= 1;
                            state <= STOP_HIGH;
                        end
                        STOP_HIGH: begin
                            scl_low <= 0;
                            phase <= 0;
                            state <= STOP_RELEASE;
                        end
                        STOP_RELEASE: begin
                            if (phase == 1) begin
                                sda_low <= 0;
                                phase <= 0;
                                state <= FINISH;
                            end else phase <= phase + 1'b1;
                        end
                        FINISH: begin
                            if (phase == 1) begin
                                busy <= 0;
                                done <= 1;
                                state <= IDLE;
                            end else phase <= phase + 1'b1;
                        end
                        default: begin
                            scl_low <= 0;
                            sda_low <= 0;
                            busy <= 0;
                            state <= IDLE;
                        end
                    endcase
                end else divider <= divider + 1'b1;
            end
        end
    end
endmodule
