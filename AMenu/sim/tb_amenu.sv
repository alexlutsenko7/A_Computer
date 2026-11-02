// tb_amenu -- machine menu: remote-update sequence, keys, error display, one video frame (menu.ppm)
//   +define+FAIL: the previous image failed (trigger CRC, previous address 0x100000 << 2 = 0x400000,
//                 which is also machine 4's address as written): the cursor must be on machine 1
//                 (the shifted match wins) with the error shown; key '4' starts machine 4 (0x400000).
//   otherwise:    power-up; Down + Enter must start machine 2 (0x200000).
`timescale 1ns/1ps
`default_nettype none

// remote update block model: reads answer after a few clocks, writes are recorded
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
    integer cnt = 0;
    reg [2:0] p; reg [1:0] rs; reg w;
    always @(posedge clock)
        if (reset) begin busy <= 0; cnt <= 0; end
        else if (!busy && write_param && read_source != 2'b00) begin
            busy <= 1; cnt <= 40; p <= 3'b000; rs <= read_source; w <= 1'b0;       // the real decoder drops it
            $display("%t RU write with read_source %b: ignored (as the device)", $time, read_source);
        end else if (!busy && (read_param || write_param)) begin
            busy <= 1; cnt <= 40; p <= param; rs <= read_source; w <= write_param;
        end else if (busy && cnt != 0) cnt <= cnt - 1;
        else if (busy) begin
            busy <= 0;
            if (w) begin
                $display("%t RU write param %b data %06h", $time, p, data_in);
                tb_amenu.wr_log.push_back({p, data_in});
            end else begin
                data_out <= (p == 3'b111 && rs == 2'b01) ? tb_amenu.TRIG :
                            (p == 3'b100 && rs == 2'b01) ? tb_amenu.PREV : 29'h1FFFFFFF;
                $display("%t RU read param %b source %b", $time, p, rs);
            end
        end
    always @(posedge reconfig) begin
        $display("%t RU reconfig", $time);
        tb_amenu.reconf = 1;
    end
endmodule

module vga_pll (input wire inclk0, output reg c0 = 0, output wire c1, output reg locked = 0);
    always #19.835 c0 = !c0;                // 25.208 MHz
    assign c1 = 1'b0;
    initial #1000 locked = 1;
endmodule

module menu_pll (input wire inclk0, output reg c0 = 0, output reg locked = 0);
    always #6.667 c0 = !c0;                 // 75 MHz (ESP32 link clock)
    initial #1000 locked = 1;
endmodule

module flash_if (input wire dclk, input wire ncs, input wire mosi, output wire miso);
    assign miso = 1'b1;                     // the configuration flash is not used here
endmodule

module tb_amenu;
`ifdef FAIL
    localparam [28:0] TRIG = 29'h08, PREV = 29'h400000;
    localparam [23:0] EXPECT = 24'h400000;
`else
    localparam [28:0] TRIG = 29'h00, PREV = 29'h000000;
    localparam [23:0] EXPECT = 24'h200000;
`endif
    reg [26:0] wr_log [$];
    reg reconf = 0;
    reg clk50 = 0, rst_n = 0, kbd_rx = 1;
    always #10 clk50 = !clk50;

    wire [3:0] r, g, b;
    wire hs, vs, led;

    AMenu #(.FONT_HEX("../rtl/menu_font.hex"), .TEXT_HEX("../rtl/menu_text.hex")) dut (
        .CLOCK_50(clk50), .RESET_N(rst_n), .LEDR(led),
        .VGA_R(r), .VGA_G(g), .VGA_B(b), .VGA_HS(hs), .VGA_VS(vs),
        .KB_OUT(kbd_rx), .KB_IN(1'b1), .AUDIO_AY(), .AUDIO_BEEP(),
        .JOY1_UP_N(1'b1), .JOY1_DOWN_N(1'b1), .JOY1_FIRE_N(1'b1),
        .JOY2_UP_N(1'b1), .JOY2_DOWN_N(1'b1), .JOY2_FIRE_N(1'b1)
    );

    task automatic uart_send(input [7:0] bt);
        integer i;
        begin
            kbd_rx = 0; #8680;
            for (i = 0; i < 8; i++) begin kbd_rx = bt[i]; #8680; end
            kbd_rx = 1; #8680;
        end
    endtask

    task automatic key_frame(input [7:0] k);
        begin
            uart_send(8'h57); uart_send(8'hAB);
            uart_send(8'h01); uart_send(8'h88); uart_send(8'h08);
            uart_send(8'h00); uart_send(8'h00);
            uart_send(k); uart_send(8'h00); uart_send(8'h00); uart_send(8'h00); uart_send(8'h00); uart_send(8'h00);
        end
    endtask

    // one frame of video -> menu.ppm (640 x 480, the colour levels scaled to 8 bits)
    integer f, px, ln, errors = 0;
    task automatic grab;
        begin
            @(negedge vs); @(posedge vs);
            f = $fopen("menu.ppm", "w");
            $fwrite(f, "P3\n640 480\n255\n");
            for (ln = 0; ln < 525; ln++) begin
                @(negedge hs);
                for (px = 0; px < 800; px++) begin
                    @(posedge dut.pclk);
                    // the pins are 2 clocks behind vga_timing: active = hcnt 144.., line 35..
                    if (ln >= 35 && ln < 515 && px >= 146 && px < 786) $fwrite(f, "%0d %0d %0d\n", r * 17, g * 17, b * 17);
                end
            end
            $fclose(f);
        end
    endtask

    initial begin
        #200 rst_n = 1;
        wait (dut.init_done);
        #1000;
        $display("%t ready: sel %0d err %0d", $time, dut.sel, dut.err);
`ifdef FAIL
        if (dut.sel != 0 || !dut.err) begin $display("FAIL: expected sel 0, err 1"); errors++; end
        grab;
        key_frame(8'h21);                   // '4'
`else
        if (dut.sel != 0 || dut.err) begin $display("FAIL: expected sel 0, err 0"); errors++; end
        key_frame(8'h51); key_frame(8'h00); // Down
        if (dut.sel != 1) begin $display("FAIL: Down did not move the cursor"); errors++; end
        grab;
        key_frame(8'h28);                   // Enter
`endif
        fork
            wait (reconf);
            #2ms;
        join_any
        if (!reconf) begin $display("FAIL: no reconfiguration"); errors++; end
        if (wr_log.size() != 3 || wr_log[0] != {3'b010, 24'h000FFF} || wr_log[1] != {3'b011, 24'd0} || wr_log[2] != {3'b100, EXPECT}) begin
            $display("FAIL: write sequence (%0d writes)", wr_log.size()); errors++;
        end
        if (errors) $display("RESULT: FAIL"); else $display("RESULT: PASS");
        $finish;
    end
endmodule
