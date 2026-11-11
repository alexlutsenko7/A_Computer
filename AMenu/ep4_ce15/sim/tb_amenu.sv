/* tb_amenu -- machine menu: remote-update sequence, keys, error display, one video frame (menu.ppm) */
/* +define+FAIL: the previous image failed (trigger CRC, previous address 0x100000 << 2 = 0x400000, */
/* which is also machine 4's address as written): the cursor must be on machine 1 */
/* (the shifted match wins) with the error shown; key '4' starts machine 4 (0x400000). */
/* otherwise:    power-up; Down + Enter must start machine 2 (0x200000). */
`timescale 1ns/1ps
`default_nettype none

/* remote update block model: reads answer after a few clocks, writes are recorded */
module altremote_update #(
    parameter check_app_pof = "false", parameter integer config_device_addr_width = 24,
    parameter integer in_data_width = 24, parameter integer out_data_width = 29,
    parameter operation_mode = "remote"
)(
    input  wire clock, input wire reset, input wire read_param, input wire write_param,
    input  wire [2:0] param, input wire [1:0] read_source, input wire [23:0] data_in,
    input  wire reconfig, input wire reset_timer, input wire ctl_nupdt,
    output reg  busy, output reg [28:0] data_out
);

/* clocks an operation of the remote update model takes */
localparam integer BUSY_CLKS = 40;
/* clocks left of the operation; what was asked */
    integer cnt = 0;
    reg [2:0] p; reg [1:0] rs; reg w;
/* one operation at a time, busy for 40 clocks */
    always @(posedge clock)
        if (reset)
        begin
            busy <= 0;
/* idle */
            cnt <= 0;
        end
        else if (!busy && write_param && read_source != 2'b00)
        begin
/* the real decoder drops it */
            busy <= 1;
            cnt <= BUSY_CLKS;
            p <= 3'b000;
/* as a read of nothing */
            rs <= read_source;
            w <= 1'b0;
            $display("%t RU write with read_source %b: ignored (as the device)", $time, read_source);
        end
/* a read or a write */
        else if (!busy && (read_param || write_param))
        begin
            busy <= 1;
            cnt <= BUSY_CLKS;
/* what was asked */
            p <= param;
            rs <= read_source;
            w <= write_param;
        end
/* busy */
        else if (busy && cnt != 0)
        begin
            cnt <= cnt - 1;
        end
        else if (busy)
        begin
/* done */
            busy <= 0;
            if (w)
            begin
                $display("%t RU write param %b data %06h", $time, p, data_in);
/* logged; a read answers with the testbench's values */
                tb_amenu.wr_log.push_back({p, data_in});
            end
            else
            begin
                data_out <= (p == 3'b111 && rs == 2'b01) ? tb_amenu.TRIG :
                            (p == 3'b100 && rs == 2'b01) ? tb_amenu.PREV : 29'h1FFFFFFF;
                $display("%t RU read param %b source %b", $time, p, rs);
            end
        end
/* a reconfiguration is noted */
    always @(posedge reconfig)
    begin
        $display("%t RU reconfig", $time);
        tb_amenu.reconf = 1;
    end
endmodule

/* PLL models */
module vga_pll (input wire inclk0, output reg c0 = 0, output wire c1, output reg locked = 0);

/* half a period of the 25.208 MHz pixel clock, ns */
localparam real PCLK_HALF = 19.835;
/* ns until a PLL model reports lock */
localparam integer LOCK_NS = 1000;
/* 25.208 MHz */
    always #PCLK_HALF c0 = !c0;
    assign c1 = 1'b0;
    initial #LOCK_NS locked = 1;
endmodule

/* 75 MHz */
module menu_pll (input wire inclk0, output reg c0 = 0, output reg locked = 0);

/* half a period of the 75 MHz clock, ns */
localparam real CLK75_HALF = 6.667;
/* ns until a PLL model reports lock */
localparam integer LOCK_NS = 1000;
/* 75 MHz (ESP32 link clock) */
    always #CLK75_HALF c0 = !c0;
    initial #LOCK_NS locked = 1;
endmodule

module flash_if (input wire dclk, input wire ncs, input wire mosi, output wire miso);
/* the configuration flash is not used here */
    assign miso = 1'b1;
endmodule

/* the testbench */
module tb_amenu;

/* half a period of the 50 MHz clock, ns */
localparam integer CLK50_HALF = 10;
/* a bit of the keyboard's UART at 115200 baud, ns */
localparam integer BIT_NS = 8680;
/* bits of a byte */
localparam integer BYTE_BITS = 8;
/* lines of a frame */
localparam integer FRAME_LINES = 525;
/* pixel clocks of a line */
localparam integer LINE_PIXELS = 800;
/* first visible line of the frame */
localparam integer PIC_Y0 = 35;
/* first line after the picture */
localparam integer PIC_Y_END = 515;
/* first pixel clock of the visible line */
localparam integer PIC_X0 = 146;
/* first pixel clock after the visible line */
localparam integer PIC_X_END = 786;
/* the reset ends after 200 ns */
localparam integer RST_NS = 200;
/* ns until a PLL model reports lock */
localparam integer LOCK_NS = 1000;
/* parameter writes the menu must make */
localparam integer WRITES = 3;
/* the watchdog time the menu must write */
localparam [23:0] WDOG_TIME = 24'h000FFF;
`ifdef FAIL
    localparam [28:0] TRIG = 29'h08, PREV = 29'h400000;
/* a failed start of machine 4 / a power-up */
    localparam [23:0] EXPECT = 24'h400000;
`else
    localparam [28:0] TRIG = 29'h00, PREV = 29'h000000;
/* the address the menu must write */
    localparam [23:0] EXPECT = 24'h200000;
`endif
    reg [26:0] wr_log [$];
/* reconfiguration seen; clock, reset, the keyboard line */
    reg reconf = 0;
    reg clk50 = 0, rst_n = 0, kbd_rx = 1;
    always #CLK50_HALF clk50 = !clk50;

/* the design under test */
    wire [3:0] r, g, b;
    wire hs, vs, led;

    AMenu #(.FONT_HEX("../rtl/menu_font.hex"), .TEXT_HEX("../rtl/menu_text.hex")) dut (
        .CLOCK_50(clk50), .RESET_N(rst_n), .LEDR(led),
        .VGA_R(r), .VGA_G(g), .VGA_B(b), .VGA_HS(hs), .VGA_VS(vs),
        .KB_OUT(kbd_rx), .KB_IN(1'b1), .AUDIO_AY(), .AUDIO_BEEP(),
        .JOY1_UP_N(1'b1), .JOY1_DOWN_N(1'b1), .JOY1_FIRE_N(1'b1),
        .JOY2_UP_N(1'b1), .JOY2_DOWN_N(1'b1), .JOY2_FIRE_N(1'b1)
    );

/* one byte on the keyboard line, 115200 baud */
    task automatic uart_send(input [7:0] bt);
        integer i;
        begin
            kbd_rx = 0;
/* start bit, 8 data bits */
            #BIT_NS;
            for (i = 0; i < BYTE_BITS; i++)
            begin
                kbd_rx = bt[i];
/* stop bit */
                #BIT_NS;
            end
            kbd_rx = 1;
            #BIT_NS;
        end
    endtask

/* one keyboard report with one key */
    task automatic key_frame(input [7:0] k);
        begin
            uart_send(8'h57);
            uart_send(8'hAB);
/* the report's header */
            uart_send(8'h01);
            uart_send(8'h88);
            uart_send(8'h08);
/* modifiers, reserved, the key */
            uart_send(8'h00);
            uart_send(8'h00);
            uart_send(k);
/* no other keys */
            uart_send(8'h00);
            uart_send(8'h00);
            uart_send(8'h00);
/* the last two */
            uart_send(8'h00);
            uart_send(8'h00);
        end
    endtask

/* one frame of video -> menu.ppm (640 x 480, the colour levels scaled to 8 bits) */
    integer f, px, ln, errors = 0;
    task automatic grab;
        begin
            @(negedge vs);
/* from the next frame's start; the PPM header */
            @(posedge vs);
            f = $fopen("menu.ppm", "w");
            $fwrite(f, "P3\n640 480\n255\n");
/* 525 lines of 800 pixels */
            for (ln = 0; ln < FRAME_LINES; ln++)
            begin
                @(negedge hs);
/* pixel by pixel */
                for (px = 0; px < LINE_PIXELS; px++)
                begin
                    @(posedge dut.pclk);
/* the pins are 2 clocks behind vga_timing: active = hcnt 144.., line 35.. */
                    if (ln >= PIC_Y0 && ln < PIC_Y_END && px >= PIC_X0 && px < PIC_X_END)
                    begin
                        $fwrite(f, "%0d %0d %0d\n", r * 17, g * 17, b * 17);
                    end
                end
            end
/* the file is complete */
            $fclose(f);
        end
    endtask

/* the test */
    initial
    begin
        #RST_NS rst_n = 1;
        wait (dut.init_done);
/* the menu's state at the start */
        #LOCK_NS;
        $display("%t ready: sel %0d err %0d", $time, dut.sel, dut.err);
`ifdef FAIL
/* after a failed start: cursor on machine 1, the error shown */
        if (dut.sel != 0 || !dut.err)
        begin
            $display("FAIL: expected sel 0, err 1");
            errors++;
        end
/* the screen */
        grab;
/* '4' */
        key_frame(8'h21);
`else
        if (dut.sel != 0 || dut.err)
        begin
/* counted */
            $display("FAIL: expected sel 0, err 0");
            errors++;
        end
/* Down */
        key_frame(8'h51);
        key_frame(8'h00);
        if (dut.sel != 1)
        begin
/* counted; the screen */
            $display("FAIL: Down did not move the cursor");
            errors++;
        end
        grab;
/* Enter */
        key_frame(8'h28);
`endif
        fork
            wait (reconf);
/* within 2 ms */
            #2ms;
        join_any
        if (!reconf)
        begin
            $display("FAIL: no reconfiguration");
/* counted; the three writes: watchdog time, watchdog off, the boot address */
            errors++;
        end
        if (wr_log.size() != WRITES || wr_log[0] != {3'b010, WDOG_TIME} || wr_log[1] != {3'b011, 24'd0} || wr_log[2] != {3'b100, EXPECT})
        begin
            $display("FAIL: write sequence (%0d writes)", wr_log.size());
/* counted; the verdict */
            errors++;
        end
        if (errors)
        begin
            $display("RESULT: FAIL");
        end
        else
        begin
/* passed */
            $display("RESULT: PASS");
        end
        $finish;
    end
endmodule
