`timescale 1ns / 1ps
//==============================================================================
// i2c_slave : 7-bit address I2C slave (Standard mode 100kHz)
//
//  Write : START | ADDR+W | reg_ptr | data0 | data1 ... | STOP
//  Read  : START | ADDR+W | reg_ptr | Sr | ADDR+R | data0(ACK) ... dataN(NACK) | STOP
//  - reg pointer auto-increments after each data byte (read / write)
//  - SDA is open-drain : drive 0 or release (Z). Never drive 1.
//  - SCL/SDA are oversampled with system clk (100MHz), synchronized and filtered.
//==============================================================================
module i2c_slave #(
    parameter [6:0] SLAVE_ADDR = 7'h42,
    parameter       FILT       = 8          // glitch filter length (clk cycles)
)(
    input            clk,
    input            reset,
    input            scl,
    inout            sda,

    // register file interface
    output reg [7:0] reg_ptr,     // current register pointer (read address)
    input      [7:0] rd_data,     // data at reg_ptr (combinational)
    output reg       wr_en,       // 1-clk pulse
    output reg [7:0] wr_addr,
    output reg [7:0] wr_data,
    output reg       start_pulse, // 1-clk pulse at every (repeated) START, for snapshot

    // debug / LED
    output reg       busy,        // START ~ STOP
    output reg       rx_toggle,   // toggles on every received data byte
    output reg       tx_toggle,   // toggles on every transmitted data byte
    output reg [7:0] last_rx      // last received data byte
);

    //--------------------------------------------------------------------------
    // open-drain SDA
    //--------------------------------------------------------------------------
    reg sda_low;                              // 1: pull SDA low
    assign sda = sda_low ? 1'b0 : 1'bz;

    //--------------------------------------------------------------------------
    // 2-FF synchronizer + glitch filter
    //--------------------------------------------------------------------------
    reg [1:0] scl_sync, sda_sync;
    always @(posedge clk) begin
        scl_sync <= {scl_sync[0], scl};
        sda_sync <= {sda_sync[0], sda};
    end

    reg       scl_f, sda_f;                   // filtered
    reg [3:0] scl_cnt, sda_cnt;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            scl_f <= 1'b1; sda_f <= 1'b1;
            scl_cnt <= 0;  sda_cnt <= 0;
        end else begin
            if (scl_sync[1] != scl_f) begin
                if (scl_cnt == FILT-1) begin scl_f <= scl_sync[1]; scl_cnt <= 0; end
                else scl_cnt <= scl_cnt + 1'b1;
            end else scl_cnt <= 0;

            if (sda_sync[1] != sda_f) begin
                if (sda_cnt == FILT-1) begin sda_f <= sda_sync[1]; sda_cnt <= 0; end
                else sda_cnt <= sda_cnt + 1'b1;
            end else sda_cnt <= 0;
        end
    end

    reg scl_d, sda_d;
    always @(posedge clk or posedge reset) begin
        if (reset) begin scl_d <= 1'b1; sda_d <= 1'b1; end
        else       begin scl_d <= scl_f; sda_d <= sda_f; end
    end

    wire scl_rise = ~scl_d &  scl_f;
    wire scl_fall =  scl_d & ~scl_f;
    wire start_det = scl_d & scl_f &  sda_d & ~sda_f;   // SDA 1->0 while SCL high
    wire stop_det  = scl_d & scl_f & ~sda_d &  sda_f;   // SDA 0->1 while SCL high

    //--------------------------------------------------------------------------
    // FSM
    //--------------------------------------------------------------------------
    localparam IDLE      = 3'd0,
               ADDR      = 3'd1,
               ACK_ADDR  = 3'd2,
               WRITE     = 3'd3,
               ACK_WRITE = 3'd4,
               READ      = 3'd5,
               READ_ACK  = 3'd6;

    reg [2:0] state;
    reg [3:0] bit_cnt;
    reg [7:0] shift;      // receive shift register
    reg [7:0] tx_shift;   // transmit shift register
    reg       rw;         // 1: master reads
    reg       first_byte; // first byte after ADDR+W is register pointer
    reg       m_ack;      // master ACK'd the byte we sent

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state       <= IDLE;
            bit_cnt     <= 0;
            shift       <= 0;
            tx_shift    <= 0;
            rw          <= 0;
            first_byte  <= 0;
            m_ack       <= 0;
            sda_low     <= 0;
            reg_ptr     <= 0;
            wr_en       <= 0;
            wr_addr     <= 0;
            wr_data     <= 0;
            start_pulse <= 0;
            busy        <= 0;
            rx_toggle   <= 0;
            tx_toggle   <= 0;
            last_rx     <= 0;
        end else begin
            wr_en       <= 1'b0;
            start_pulse <= 1'b0;

            if (start_det) begin                 // START / repeated START (highest priority)
                state       <= ADDR;
                bit_cnt     <= 0;
                sda_low     <= 1'b0;
                busy        <= 1'b1;
                start_pulse <= 1'b1;
            end else if (stop_det) begin         // STOP
                state   <= IDLE;
                sda_low <= 1'b0;
                busy    <= 1'b0;
            end else begin
                case (state)
                //--------------------------------------------------------------
                IDLE: sda_low <= 1'b0;

                //--------------------------------------------------------------
                ADDR: begin
                    if (scl_rise && bit_cnt < 8) begin
                        shift   <= {shift[6:0], sda_f};
                        bit_cnt <= bit_cnt + 1'b1;
                    end else if (scl_fall && bit_cnt == 8) begin
                        if (shift[7:1] == SLAVE_ADDR) begin
                            rw      <= shift[0];
                            sda_low <= 1'b1;        // ACK
                            state   <= ACK_ADDR;
                        end else begin
                            state   <= IDLE;        // not me : ignore until next START
                        end
                    end
                end

                //--------------------------------------------------------------
                ACK_ADDR: begin
                    if (scl_fall) begin             // end of 9th clock
                        if (rw) begin               // master read : output MSB now
                            sda_low  <= ~rd_data[7];
                            tx_shift <= {rd_data[6:0], 1'b0};
                            bit_cnt  <= 1;
                            state    <= READ;
                        end else begin
                            sda_low    <= 1'b0;
                            bit_cnt    <= 0;
                            first_byte <= 1'b1;
                            state      <= WRITE;
                        end
                    end
                end

                //--------------------------------------------------------------
                WRITE: begin
                    if (scl_rise && bit_cnt < 8) begin
                        shift   <= {shift[6:0], sda_f};
                        bit_cnt <= bit_cnt + 1'b1;
                    end else if (scl_fall && bit_cnt == 8) begin
                        sda_low <= 1'b1;            // ACK
                        state   <= ACK_WRITE;
                        if (first_byte) begin
                            reg_ptr    <= shift;
                            first_byte <= 1'b0;
                        end else begin
                            wr_en     <= 1'b1;
                            wr_addr   <= reg_ptr;
                            wr_data   <= shift;
                            last_rx   <= shift;
                            rx_toggle <= ~rx_toggle;
                            reg_ptr   <= reg_ptr + 1'b1;
                        end
                    end
                end

                ACK_WRITE: begin
                    if (scl_fall) begin
                        sda_low <= 1'b0;            // release
                        bit_cnt <= 0;
                        state   <= WRITE;
                    end
                end

                //--------------------------------------------------------------
                READ: begin
                    if (scl_fall) begin
                        if (bit_cnt == 8) begin     // 8 bits sent -> release for ACK
                            sda_low   <= 1'b0;
                            reg_ptr   <= reg_ptr + 1'b1;
                            tx_toggle <= ~tx_toggle;
                            state     <= READ_ACK;
                        end else begin
                            sda_low  <= ~tx_shift[7];
                            tx_shift <= {tx_shift[6:0], 1'b0};
                            bit_cnt  <= bit_cnt + 1'b1;
                        end
                    end
                end

                READ_ACK: begin
                    if (scl_rise) begin
                        m_ack <= ~sda_f;            // 0 = ACK, 1 = NACK
                    end else if (scl_fall) begin
                        if (m_ack) begin            // send next byte
                            sda_low  <= ~rd_data[7];
                            tx_shift <= {rd_data[6:0], 1'b0};
                            bit_cnt  <= 1;
                            state    <= READ;
                        end else begin              // NACK : wait STOP
                            sda_low <= 1'b0;
                            state   <= IDLE;
                        end
                    end
                end

                default: state <= IDLE;
                endcase
            end
        end
    end

endmodule
