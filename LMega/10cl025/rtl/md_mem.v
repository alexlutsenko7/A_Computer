/* md_mem -- LMega: everything the Mega Drive keeps in the SDRAM, and who may use it when */
/* */
/* SDRAM byte addresses (23 bits): */
/* 0x000000-0x3FFFFF  cartridge ROM, in the file's byte order */
/* 0x400000-0x40FFFF  the 68000's RAM */
/* 0x410000-0x41FFFF  the VDP's video RAM */
/* 0x420000-0x42FFFF  cartridge RAM (battery) */
/* 0x500000-0x5BFFFF  frame buffers of the 50-into-60 Hz video mode (md_fb.v) */
/* A 68000 word has its high byte at the even address: the low byte lane of the SDRAM word. */
/* */
/* Users, by priority (clk_sd = 2 x mclk, edges aligned; the requests come from mclk registers): */
/* 1 the VDP's 32-bit video RAM read (two words; request = vram32_req != vram32_ack) */
/* 2 the VDP's 16-bit video RAM access (the same handshake) */
/* 3 the machine's bus (mem_req != mem_ack) */
/* 4 the frame buffer: reads in runs of 8 words (fbr_req held until fbr_ack; fbr_stb with each word in */
/* fb_q), then single word writes (fbw_req held until fbw_ack) */
/* 5 the ESP32's memory port (bytes: x_req held until x_ack) */
/* 6 the clear of RAM and video RAM when a cartridge was loaded (clr_go; clr_done when finished) */
`default_nettype none

module md_mem #(
    parameter integer SD_MHZ = 108
)(
    input  wire        clk_sd,
    input  wire        rst_sd_n,

/* the machine's bus */
    input  wire        mem_req,
    output reg         mem_ack,
    input  wire        mem_we,
    input  wire [23:1] mem_addr,
    input  wire [1:0]  mem_be,
    input  wire [15:0] mem_wdata,
    output reg  [15:0] mem_rdata,

/* the VDP */
    input  wire        vram_req,
    output reg         vram_ack,
    input  wire        vram_we,
    input  wire [15:1] vram_a,
    input  wire [15:0] vram_d,
    output reg  [15:0] vram_q,
    input  wire        vram_u_n,
    input  wire        vram_l_n,
    input  wire        vram32_req,
    output reg         vram32_ack,
    input  wire [15:1] vram32_a,
    output reg  [31:0] vram32_q,

/* the frame buffer (md_fb) */
    input  wire        fbr_req,
    input  wire [22:0] fbr_addr,
    output wire        fbr_ack,
    output wire        fbr_stb,
    input  wire        fbw_req,
    input  wire [22:0] fbw_addr,
    input  wire [15:0] fbw_data,
    output wire        fbw_ack,
    output wire [15:0] fb_q,

/* the ESP32 */
    input  wire        x_req,
    input  wire        x_we,
    input  wire [22:0] x_addr,
    input  wire [7:0]  x_din,
    output wire        x_ack,
    output wire [7:0]  x_dout,

/* clear RAM and video RAM (level; clr_done follows it) */
    input  wire        clr_go,
    output reg         clr_done,

/* SDRAM */
    output wire        sd_cke,
    output wire        sd_cs_n,
    output wire        sd_ras_n,
    output wire        sd_cas_n,
    output wire        sd_we_n,
    output wire [1:0]  sd_ba,
    output wire [12:0] sd_a,
    output wire [1:0]  sd_dqm,
    output wire [15:0] sd_dq_o,
    output wire        sd_dq_oe,
    input  wire [15:0] sd_dq_i
);

/* access owners */
localparam [2:0] OWN_V32A = 3'd0;
localparam [2:0] OWN_V32B = 3'd1;
localparam [2:0] OWN_VRAM = 3'd2;
/* the bus, the ESP32, the clear */
localparam [2:0] OWN_MEM  = 3'd3;
localparam [2:0] OWN_X    = 3'd4;
localparam [2:0] OWN_CLR  = 3'd5;
/* the frame buffer: run read, word write */
localparam [2:0] OWN_FBR  = 3'd6;
localparam [2:0] OWN_FBW  = 3'd7;
/* words of a frame buffer run read */
localparam integer FB_RUN = 8;
/* the video RAM's place: 0x410000 */
localparam [6:0] AREA_VRAM = 7'b100_0001;
/* the clear: 0x400000-0x41FFFF, in words */
localparam [5:0] AREA_CLR = 6'b10_0000;

reg         a_req, a_busy, a_we, a_wide, a_run;
reg  [2:0]  a_own;
/* its address and data */
reg  [22:0] a_addr;
reg  [7:0]  a_din, a_dhi;
reg  [7:0]  x_q;
/* the ESP32's access is done */
reg         x_done;
reg  [15:0] clr_a;
reg         clr_run;
/* the second word of a 32-bit read is still to come */
reg         v32_more;
/* the clear request, synchronised */
reg  [1:0]  clr_s;
wire [7:0]  ram_dout;
wire [15:0] ram_dout_w;
/* the SDRAM controller's answers */
wire        ram_ack, ram_ready, ram_run_stb;
/* which bytes a 16-bit access writes: both = one word access, else one byte */
wire        v_both = !vram_u_n && !vram_l_n;
wire        m_both = mem_be == 2'b11;

always @(posedge clk_sd or negedge rst_sd_n)
/* at reset */
    if (!rst_sd_n)
    begin
        mem_ack    <= 1'b0;
        vram_ack   <= 1'b0;
/* no answers yet */
        vram32_ack <= 1'b0;
        mem_rdata  <= 16'd0;
        vram_q     <= 16'd0;
/* no read data */
        vram32_q   <= 32'd0;
/* no access */
        a_req  <= 1'b0;
        a_busy <= 1'b0;
        a_we   <= 1'b0;
/* a byte access */
        a_wide <= 1'b0;
        a_run  <= 1'b0;
        a_own  <= OWN_MEM;
/* no data */
        a_addr <= 23'd0;
/* no data */
        a_din  <= 8'd0;
        a_dhi  <= 8'd0;
/* the ESP32's port, the clear */
        x_q    <= 8'hFF;
        x_done <= 1'b0;
        clr_a  <= 16'd0;
/* no clear running */
        clr_run <= 1'b0;
        clr_done <= 1'b0;
        clr_s  <= 2'b00;
/* no second word pending */
        v32_more <= 1'b0;
    end
    else
    begin
/* one access at a time */
        a_req <= 1'b0;
        clr_s <= {clr_s[0], clr_go};
        if (!x_req)
        begin
/* the ESP32 took its answer */
            x_done <= 1'b0;
        end
/* the clear starts with its request and is forgotten when the request goes */
        if (!clr_s[1])
        begin
            clr_done <= 1'b0;
            clr_run  <= 1'b0;
/* its address starts again */
            clr_a    <= 16'd0;
        end
        else if (!clr_done && !clr_run)
        begin
            clr_run <= 1'b1;
        end

/* the SDRAM is free: the next user by priority */
        if (!a_busy)
        begin
            a_wide <= 1'b1;
            a_we   <= 1'b0;
/* not a run unless said */
            a_run  <= 1'b0;
/* the second word of a 32-bit read comes before anything else. (The SDRAM controller wants a */
/* clock between an access and the next request: it is not asked for in the first one's last clock.) */
            if (v32_more)
            begin
                v32_more <= 1'b0;
                a_busy   <= 1'b1;
/* its request: the word after the first */
                a_req    <= 1'b1;
                a_own    <= OWN_V32B;
                a_addr   <= {a_addr[22:2], 2'b10};
            end
/* the VDP's 32-bit read: the first of two words */
            else if (vram32_req != vram32_ack)
            begin
                a_busy <= 1'b1;
                a_req  <= 1'b1;
/* the first word's address */
                a_own  <= OWN_V32A;
                a_addr <= {AREA_VRAM, vram32_a[15:2], 2'b00};
            end
/* the VDP's 16-bit access */
            else if (vram_req != vram_ack)
            begin
                a_busy <= 1'b1;
                a_req  <= 1'b1;
/* a word, or one byte of it when written */
                a_own  <= OWN_VRAM;
                a_we   <= vram_we;
                a_wide <= !vram_we || v_both;
/* the upper byte alone goes to the odd address */
                a_addr <= {AREA_VRAM, vram_a, vram_we && !v_both && vram_l_n};
                a_din  <= (vram_we && !v_both && vram_l_n) ? vram_d[15:8] : vram_d[7:0];
                a_dhi  <= vram_d[15:8];
            end
/* the machine's bus: the high byte is the low lane */
            else if (mem_req != mem_ack)
            begin
                a_busy <= 1'b1;
                a_req  <= 1'b1;
/* a word, or one byte of it when written */
                a_own  <= OWN_MEM;
                a_we   <= mem_we;
                a_wide <= !mem_we || m_both;
/* the lower byte alone goes to the odd address */
                a_addr <= {mem_addr[22:1], mem_we && !m_both && mem_be[0]};
                a_din  <= (mem_we && !m_both && mem_be[0]) ? mem_wdata[7:0] : mem_wdata[15:8];
                a_dhi  <= mem_wdata[7:0];
            end
/* the frame buffer: a run of words for the screen, then a pixel word to store */
            else if (fbr_req)
            begin
                a_busy <= 1'b1;
                a_req  <= 1'b1;
/* a run of words */
                a_own  <= OWN_FBR;
                a_run  <= 1'b1;
                a_addr <= fbr_addr;
            end
/* a pixel word */
            else if (fbw_req)
            begin
                a_busy <= 1'b1;
                a_req  <= 1'b1;
/* a word write */
                a_own  <= OWN_FBW;
                a_we   <= 1'b1;
                a_addr <= fbw_addr;
/* its data */
                a_din  <= fbw_data[7:0];
                a_dhi  <= fbw_data[15:8];
            end
/* the ESP32 */
            else if (x_req && !x_done)
            begin
                a_busy <= 1'b1;
                a_req  <= 1'b1;
/* a byte access */
                a_own  <= OWN_X;
                a_wide <= 1'b0;
                a_we   <= x_we;
/* its address and data */
                a_addr <= x_addr;
                a_din  <= x_din;
            end
/* the clear, word by word */
            else if (clr_run)
            begin
                a_busy <= 1'b1;
                a_req  <= 1'b1;
/* a word of zeros */
                a_own  <= OWN_CLR;
                a_we   <= 1'b1;
                a_addr <= {AREA_CLR, clr_a, 1'b0};
/* zeros */
                a_din  <= 8'd0;
                a_dhi  <= 8'd0;
            end
        end
        else if (ram_ack)
        begin
/* the access is over: the data goes to its owner */
            a_busy <= 1'b0;
            case (a_own)
/* the first word: the second one is asked for next */
                OWN_V32A:
                begin
                    vram32_q[15:0] <= ram_dout_w;
                    v32_more       <= 1'b1;
                end
/* the 32-bit read is complete */
                OWN_V32B:
                begin
                    vram32_q[31:16] <= ram_dout_w;
                    vram32_ack      <= vram32_req;
                end
/* the 16-bit access */
                OWN_VRAM:
                begin
                    vram_q   <= ram_dout_w;
                    vram_ack <= vram_req;
                end
/* the bus */
                OWN_MEM:
                begin
                    mem_rdata <= {ram_dout_w[7:0], ram_dout_w[15:8]};
                    mem_ack   <= mem_req;
                end
/* the ESP32 */
                OWN_X:
                begin
                    if (!a_we)
                    begin
                        x_q <= ram_dout;
                    end
/* its access is done */
                    x_done <= 1'b1;
                end
/* the frame buffer's accesses answer through fbr_ack / fbw_ack */
                OWN_FBR, OWN_FBW: ;
/* the clear: the next word, or done */
                default:
                begin
                    clr_a <= clr_a + 16'd1;
                    if (&clr_a)
                    begin
/* all 128 KB are cleared */
                        clr_run  <= 1'b0;
                        clr_done <= 1'b1;
                    end
                end
            endcase
        end
    end

assign fbr_ack = a_busy && a_own == OWN_FBR && ram_ack;
/* the frame buffer's answers and data */
assign fbw_ack = a_busy && a_own == OWN_FBW && ram_ack;
assign fbr_stb = ram_run_stb;
assign fb_q    = ram_dout_w;
/* the ESP32's answers */
assign x_ack  = x_done;
/* the SDRAM controller */
assign x_dout = x_q;

md_sdram #(.ADDR_BITS(23), .CLK_MHZ(SD_MHZ), .RUN(FB_RUN)) u_ram (
    .clk      (clk_sd),
    .rst_n    (rst_sd_n),
    .req      (a_req),
    .we       (a_we),
    .addr     (a_addr),
    .din      (a_din),
    .wide     (a_wide),
    .din_hi   (a_dhi),
    .run      (a_run),
    .run_stb  (ram_run_stb),
    .dout     (ram_dout),
    .dout_w   (ram_dout_w),
    .ack      (ram_ack),
    .ready    (ram_ready),
    .sd_cke   (sd_cke),
    .sd_cs_n  (sd_cs_n),
    .sd_ras_n (sd_ras_n),
    .sd_cas_n (sd_cas_n),
    .sd_we_n  (sd_we_n),
    .sd_ba    (sd_ba),
    .sd_a     (sd_a),
    .sd_dqm   (sd_dqm),
    .sd_dq_o  (sd_dq_o),
    .sd_dq_oe (sd_dq_oe),
    .sd_dq_i  (sd_dq_i)
);

endmodule

`default_nettype wire
