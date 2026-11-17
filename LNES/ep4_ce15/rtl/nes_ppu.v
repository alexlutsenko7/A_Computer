/* nes_ppu -- LNES: the picture processor (the NES's 2C02, NTSC), our own design */
/* */
/* Written from the public NESdev documentation only (register behaviour, the fetch pattern of a */
/* line, the scroll registers v / t / x / w, sprite evaluation); no other core's HDL was used. */
/* */
/* Time base: clk = 4 per dot (ph 0..3, a dot ends with ph = 3); 341 dots per line (hc 0..340), */
/* 262 lines (vc 0..261): 0-239 the picture, 241 dot 1 the vertical blank flag (NMI), 261 the */
/* pre-render line, one dot shorter in every second frame while rendering is on. */
/* */
/* A line with rendering on (picture and pre-render lines): */
/* dots 1-256, 321-336   background, 8 dots per tile: name byte (dot 1 of the group), attribute */
/* byte (dot 3), the two pattern bytes (asked for after dot 1, taken at dot 8) */
/* dots 65-128           sprite evaluation for the next line (picture lines): up to 8 sprites */
/* dots 257-320          the sprites' pattern bytes, 8 dots per sprite */
/* dot 256 / 257         v: next row / the horizontal part of t; pre-render 280-304: the vertical part */
/* */
/* Memories: */
/* name tables  4 KB block RAM (mirror: 0 horizontal, 1 vertical, 2 / 3 one screen A / B, 4 four) */
/* sprites      256 bytes block RAM; palette 32 x 6 bits in registers */
/* patterns     in the SDRAM (nes_system): one request (pt_tgl toggles, pt_addr = the address of */
/* the low plane byte) returns both planes of a tile row in pt_q ({high, low}) well */
/* before they are taken (5 dots later at least) */
/* The two block RAMs are shared by time: ph 0 / 1 the picture's read, ph 2 / 3 the CPU's access. */
/* */
/* CPU side: reg_we / reg_re are one clk long at ph = 1; reg_q is registered there. A read or write */
/* of $2007 below $2000 is the system's (SDRAM): it reads v_o and gives the byte in chr_q before */
/* the dot ends. */
/* a12 = bit 12 of the address the real chip would show (mappers with a line counter). */
/* Pixels: px_stb with px_x, px_y, px_c (colour 0-63) and px_e (the three emphasis bits) for each */
/* of the 256 x 240; px_eof once per frame, after the last line. */
`default_nettype none

module nes_ppu (
    input  wire        clk,
    input  wire        rst_n,
/* phase of the dot */
    input  wire [1:0]  ph,

/* registers $2000-$2007 */
    input  wire        reg_we,
    input  wire        reg_re,
    input  wire [2:0]  reg_a,
    input  wire [7:0]  reg_d,
    output reg  [7:0]  reg_q,
    output wire        nmi_n,

/* cartridge: name table layout, pattern memory */
    input  wire [2:0]  mirror,
    output wire [14:0] v_o,
    input  wire [7:0]  chr_q,
    output reg         pt_tgl,
    output reg  [12:0] pt_addr,
    input  wire [15:0] pt_q,
    output reg         a12,

/* the picture */
    output reg         px_stb,
    output reg  [7:0]  px_x,
    output reg  [7:0]  px_y,
    output reg  [5:0]  px_c,
    output reg  [2:0]  px_e,
    output reg         px_eof
);

/* last dot of a line */
localparam [8:0] H_LAST = 9'd340;
/* the dot after which the short pre-render line ends */
localparam [8:0] H_SKIP = 9'd339;
/* last dot of the picture */
localparam [8:0] H_PIC_LAST = 9'd256;
/* first and last dot of the sprites' pattern fetches */
localparam [8:0] H_SPR_FIRST = 9'd257;
localparam [8:0] H_SPR_LAST = 9'd320;
/* first and last dot of the fetches for the next line's first two tiles */
localparam [8:0] H_PRE_FIRST = 9'd321;
localparam [8:0] H_PRE_LAST = 9'd336;
/* the dot before the sprite evaluation starts; its last dot */
localparam [8:0] H_EVAL_START = 9'd64;
localparam [8:0] H_EVAL_LAST = 9'd128;
/* pre-render line: v takes the vertical part of t in these dots */
localparam [8:0] H_VCOPY_FIRST = 9'd280;
localparam [8:0] H_VCOPY_LAST = 9'd304;
/* lines: the picture, the vertical blank flag, the pre-render line */
localparam [8:0] V_PIC = 9'd240;
localparam [8:0] V_VBL = 9'd241;
localparam [8:0] V_PRE = 9'd261;
/* registers */
localparam [2:0] R_STATUS = 3'd2;
localparam [2:0] R_OAMADDR = 3'd3;
localparam [2:0] R_OAMDATA = 3'd4;
/* scroll, address, data */
localparam [2:0] R_SCROLL = 3'd5;
localparam [2:0] R_ADDR = 3'd6;
localparam [2:0] R_DATA = 3'd7;
/* the palette's page of the address space */
localparam [5:0] PAGE_PAL = 6'h3F;
/* coarse Y: the last row of a name table, and the last value of the counter */
localparam [4:0] ROW_LAST = 5'd29;
/* the third byte of a sprite has no bits 4:2 */
localparam [7:0] ATTR_MASK = 8'hE3;
/* sprites of a line */
localparam [3:0] SPR_MAX = 4'd8;
/* the last sprite of the table */
localparam [5:0] OAM_LAST = 6'd63;
/* tile fetch steps: the attribute byte, the sprite's attribute, the last dot of a group */
localparam [2:0] SUB_AT = 3'd2;
localparam [2:0] SUB_SPR_REQ = 3'd2;
localparam [2:0] SUB_X = 3'd3;
/* the pattern bytes' steps */
localparam [2:0] SUB_PAT = 3'd4;
localparam [2:0] SUB_LAST = 3'd7;
/* the left eight pixels can be hidden; the last pixel never gives a sprite 0 hit */
localparam [7:0] X_CLIP = 8'd8;
/* grey mode keeps the brightness bits of a colour */
localparam [5:0] GREY_MASK = 6'h30;
/* mirror modes */
localparam [2:0] MIR_V = 3'd1;
localparam [2:0] MIR_A = 3'd2;
localparam [2:0] MIR_B = 3'd3;
/* bits of the status register that are not driven */
localparam integer STATUS_OPEN = 5;
/* sprite units of a line, palette entries; $2007 steps the address by a row of 32 cells or by 1 */
localparam integer SPRITES = 8;
localparam integer PAL_ENTRIES = 32;
localparam [14:0] V_STEP_ROW = 15'd32;

/* a loop counter */
integer i;

/* Registers */
reg  [7:0]  ctrl, mask;
reg         vbl, s0hit, ovf, vbl_block;
/* scroll: current and temporary address, fine x, the write toggle */
reg  [14:0] v, t;
reg  [2:0]  fx;
reg         w;
/* the read buffer of $2007, the sprite address, the last value on the data lines */
reg  [7:0]  rd_buf, oamaddr, ob;

/* Counters */
reg  [8:0]  hc, vc;
reg         odd;
wire        dot_end = ph == 2'b11;
/* the middle of a dot (memory answers), the CPU's memory slot */
wire        ph_lat  = ph == 2'b01;
wire        ph_cpu  = ph == 2'b10;
/* rendering on; the line is a picture line / the pre-render line */
wire        ren  = mask[3] | mask[4];
wire        vis  = vc < V_PIC;
wire        pre  = vc == V_PRE;
/* a line that is drawn or prepared */
wire        rl   = ren && (vis || pre);
/* the parts of a line */
wire        in_pic = hc != 9'd0 && hc <= H_PIC_LAST;
wire        in_bg  = in_pic || (hc >= H_PRE_FIRST && hc <= H_PRE_LAST);
wire        in_sp  = hc >= H_SPR_FIRST && hc <= H_SPR_LAST;
/* step inside a group of 8 dots, and the sprite of the group */
wire [8:0]  hm1  = hc - 9'd1;
wire [2:0]  sub  = hm1[2:0];
wire [2:0]  slot = hm1[5:3];

/* the scroll address for the system; the interrupt line */
assign v_o   = v;
assign nmi_n = !(vbl && ctrl[7]);

/* Name tables: 4 KB, the cartridge's mirroring picks the page */
function [1:0] nt_page(input [1:0] p);
    case (mirror)
        3'd0:    nt_page = {1'b0, p[1]};
/* vertical mirroring: left and right differ */
        MIR_V:   nt_page = {1'b0, p[0]};
        MIR_A:   nt_page = 2'b00;
        MIR_B:   nt_page = 2'b01;
/* four screens */
        default: nt_page = p;
    endcase
endfunction

/* the CPU's pending accesses (set at its strobe, done in ph 2 / 3 of the same dot) */
reg         c_wr_nt, c_rd_nt, c_rd_chr, c_wr_oam;
reg  [11:0] c_addr;
reg  [7:0]  c_data;

/* the picture's address: the attribute byte at step 2 of a group, else the name byte */
wire [11:0] nt_ra = sub[1] ? {v[11:10], 4'b1111, v[9:7], v[4:2]} : v[11:0];
wire [11:0] nt_a  = ph_cpu ? {nt_page(c_addr[11:10]), c_addr[9:0]} : {nt_page(nt_ra[11:10]), nt_ra[9:0]};
wire        nt_we = ph_cpu && c_wr_nt;
/* the memory itself */
reg  [7:0]  nt_ram [0:4095];
reg  [7:0]  nt_q;
/* the name table memory */
always @(posedge clk)
begin
    if (nt_we)
    begin
        nt_ram[nt_a] <= c_data;
    end
/* its registered read */
    nt_q <= nt_ram[nt_a];
end

/* Sprite table: 256 bytes */
reg  [5:0]  sec_idx [0:7];
reg  [6:0]  ev_n;
reg  [1:0]  ev_m;
/* sprites found, evaluation finished */
reg  [3:0]  ev_cnt;
reg         ev_done;
/* the picture's address: the evaluation's byte, or a byte of the sprite being fetched */
wire [7:0]  oam_ra = in_sp ? {sec_idx[slot], sub[1:0]} : {ev_n[5:0], ev_m};
wire [7:0]  oam_a  = ph_cpu ? oamaddr : oam_ra;
wire        oam_we = ph_cpu && c_wr_oam;
/* the memory itself */
reg  [7:0]  oam_ram [0:255];
reg  [7:0]  oam_q, oam_cpu_q;
/* the sprite memory */
always @(posedge clk)
begin
    if (oam_we)
    begin
        oam_ram[oam_a] <= c_data;
    end
/* its registered read */
    oam_q <= oam_ram[oam_a];
end

/* Palette: 32 entries of 6 bits; entries 16, 20, 24, 28 are entries 0, 4, 8, 12 */
function [4:0] pal_slot(input [4:0] a);
    pal_slot = a[1:0] == 2'b00 ? {1'b0, a[3:0]} : a;
endfunction
reg  [5:0]  pal [0:31];

/* Background: fetch latches and shift registers */
reg  [7:0]  nt_byte;
reg  [1:0]  at_bits, at_lat;
reg  [15:0] bg_lo, bg_hi;
/* the attribute shifters */
reg  [7:0]  at_lo, at_hi;
/* the attribute byte's two bits for the tile at v */
wire [7:0]  at_shifted = v[6] ? (v[1] ? {6'd0, nt_q[7:6]} : {6'd0, nt_q[5:4]}) :
                                (v[1] ? {6'd0, nt_q[3:2]} : {6'd0, nt_q[1:0]});

/* Sprites: the eight units of a line and the fetch latches */
reg  [7:0]  sp_lo [0:7];
reg  [7:0]  sp_hi [0:7];
reg  [7:0]  sp_x  [0:7];
/* priority and palette of each unit */
reg  [2:0]  sp_at [0:7];
reg  [7:0]  f_y, f_tile, f_attr, f_x;
reg         s0_line;
/* the sprite of this group exists */
wire        f_valid = {1'b0, slot} < ev_cnt;
wire        h16     = ctrl[5];
/* its row, turned over when flipped vertically */
wire [7:0]  f_dy    = vc[7:0] - f_y;
wire [3:0]  f_row   = f_attr[7] ? ~f_dy[3:0] : f_dy[3:0];
wire [12:0] f_addr  = h16 ? {f_tile[0], f_tile[7:1], f_row[3], 1'b0, f_row[2:0]} :
                            {ctrl[3], f_tile, 1'b0, f_row[2:0]};
/* its pattern table, or the tile's low bit with tall sprites */
wire        f_a12   = h16 ? (f_valid ? f_tile[0] : 1'b1) : ctrl[3];

/* bit order turned for a horizontal flip */
function [7:0] rev8(input [7:0] d);
    rev8 = {d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]};
endfunction

/* evaluation: is the byte just read the Y of a sprite on this line? */
wire [7:0]  ev_dy  = vc[7:0] - oam_q;
wire        ev_in  = vc[7:0] >= oam_q && (h16 ? ev_dy[7:4] == 4'd0 : ev_dy[7:3] == 5'd0);
wire        in_ev  = vis && ren && hc > H_EVAL_START && hc <= H_EVAL_LAST;

/* The pixel of this dot */
wire [7:0]  xpos   = hm1[7:0];
wire        left8  = xpos < X_CLIP;
wire [3:0]  fxi    = {1'b0, fx};
/* the background's pixel and its palette */
wire [1:0]  bg_raw = {bg_hi[4'd15 - fxi], bg_lo[4'd15 - fxi]};
wire [1:0]  bg_atr = {at_hi[3'd7 - fx], at_lo[3'd7 - fx]};
wire        bg_on  = mask[3] && !(left8 && !mask[1]);
/* sprites shown here */
wire        sp_on  = mask[4] && !(left8 && !mask[2]);
wire [1:0]  bgp    = bg_on ? bg_raw : 2'b00;

/* the first sprite unit with a pixel here */
reg  [1:0]  spp;
reg  [2:0]  spa;
reg         sp0;
/* the units' priority */
always @*
begin
    spp = 2'b00;
    spa = 3'b000;
/* not sprite 0 */
    sp0 = 1'b0;
/* from the last unit to the first: the first one wins */
    for (i = SPRITES - 1; i >= 0; i = i - 1)
    begin
        if (sp_x[i] == 8'd0 && (sp_hi[i][7] || sp_lo[i][7]))
        begin
            spp = {sp_hi[i][7], sp_lo[i][7]};
/* its attributes; is it sprite 0? */
            spa = sp_at[i];
            sp0 = i == 0;
        end
    end
/* sprites off, or hidden at the left edge */
    if (!sp_on)
    begin
        spp = 2'b00;
        sp0 = 1'b0;
    end
end

/* sprite before background, unless it is behind and the background is not transparent */
wire        spr_wins = spp != 2'b00 && (bgp == 2'b00 || !spa[2]);
wire [4:0]  pix_idx  = spr_wins        ? {1'b1, spa[1:0], spp} :
                       bgp != 2'b00    ? {1'b0, bg_atr, bgp}   : 5'd0;
/* rendering off: the backdrop, or the palette entry v points at */
wire [4:0]  off_idx  = v[13:8] == PAGE_PAL ? v[4:0] : 5'd0;
wire [4:0]  out_idx  = ren ? pix_idx : off_idx;
/* one palette read: the CPU's at its strobe, the pixel's else */
wire [4:0]  pal_ra   = ph_lat ? v[4:0] : out_idx;
wire [5:0]  pal_q    = pal[pal_slot(pal_ra)];

/* what the real chip would have on address line 12 */
wire        a12_now = !rl               ? v[12] :
                      in_bg             ? (sub >= SUB_PAT && ctrl[4]) :
                      in_sp             ? (sub >= SUB_PAT && f_a12)   : 1'b0;

/* v + 1 column, v + 1 row (the scroll counters of the real chip) */
wire [14:0] v_incx = v[4:0] == 5'h1F ? {v[14:11], !v[10], v[9:5], 5'd0} : {v[14:5], v[4:0] + 5'd1};
wire        fy_max = v[14:12] == 3'b111;
wire [4:0]  cy_nxt = (v[9:5] == ROW_LAST || v[9:5] == 5'h1F) ? 5'd0 : v[9:5] + 5'd1;

/* $2007 steps v by 1 or 32 */
wire [14:0] v_step = v + (ctrl[2] ? V_STEP_ROW : 15'd1);
wire        v_pal  = v[13:8] == PAGE_PAL;

/* The whole chip */
always @(posedge clk or negedge rst_n)
    if (!rst_n)
    begin
        ctrl <= 8'd0;
/* the mask register */
        mask <= 8'd0;
/* no flags */
        vbl <= 1'b0;
        s0hit <= 1'b0;
        ovf <= 1'b0;
/* no blocked flag */
        vbl_block <= 1'b0;
/* scroll */
        v <= 15'd0;
        t <= 15'd0;
        fx <= 3'd0;
/* first write next */
        w <= 1'b0;
/* buffers */
        rd_buf <= 8'd0;
        oamaddr <= 8'd0;
        ob <= 8'd0;
/* the answer register */
        reg_q <= 8'd0;
/* the frame starts */
        hc <= 9'd0;
        vc <= 9'd0;
        odd <= 1'b0;
/* nothing pending */
        c_wr_nt <= 1'b0;
        c_rd_nt <= 1'b0;
        c_rd_chr <= 1'b0;
/* no sprite write */
        c_wr_oam <= 1'b0;
        c_addr <= 12'd0;
        c_data <= 8'd0;
/* the sprite byte for the CPU */
        oam_cpu_q <= 8'd0;
/* evaluation */
        ev_n <= 7'd0;
        ev_m <= 2'd0;
        ev_cnt <= 4'd0;
/* not finished */
        ev_done <= 1'b0;
        s0_line <= 1'b0;
/* fetches */
        nt_byte <= 8'd0;
        at_bits <= 2'd0;
        at_lat <= 2'd0;
/* the pattern shifters */
        bg_lo <= 16'd0;
        bg_hi <= 16'd0;
        at_lo <= 8'd0;
/* the attribute shifters */
        at_hi <= 8'd0;
/* the sprite being fetched */
        f_y <= 8'd0;
        f_tile <= 8'd0;
        f_attr <= 8'd0;
/* its column */
        f_x <= 8'd0;
/* outputs */
        pt_tgl <= 1'b0;
        pt_addr <= 13'd0;
        a12 <= 1'b0;
/* no pixel yet */
        px_stb <= 1'b0;
        px_x <= 8'd0;
        px_y <= 8'd0;
/* colour and emphasis */
        px_c <= 6'd0;
        px_e <= 3'd0;
        px_eof <= 1'b0;
/* the sprite units and the palette */
        for (i = 0; i < SPRITES; i = i + 1)
        begin
            sp_lo[i] <= 8'd0;
            sp_hi[i] <= 8'd0;
/* its column and attributes */
            sp_x[i] <= 8'd0;
            sp_at[i] <= 3'd0;
            sec_idx[i] <= 6'd0;
        end
/* the palette: all black */
        for (i = 0; i < PAL_ENTRIES; i = i + 1)
        begin
            pal[i] <= 6'd0;
        end
    end
    else
    begin
        px_stb <= 1'b0;
/* the frame end pulse */
        px_eof <= 1'b0;
        a12    <= a12_now;

/* ---- the middle of a dot: what the picture's memory reads returned ---- */
        if (ph_lat)
        begin
            if (rl && in_bg)
            begin
/* the name byte, the attribute bits */
                if (sub == 3'd0)
                begin
                    nt_byte <= nt_q;
                end
                if (sub == SUB_AT)
                begin
/* the two attribute bits of this tile */
                    at_bits <= at_shifted[1:0];
                end
            end
/* the four bytes of the sprite being fetched */
            if (rl && in_sp)
            begin
                case (sub)
                    3'd0:    f_y    <= oam_q;
/* tile, attributes, column */
                    3'd1:    f_tile <= oam_q;
                    SUB_AT:  f_attr <= oam_q;
                    SUB_X:   f_x    <= oam_q;
/* steps 4-7 fetch nothing from this memory */
                    default: ;
                endcase
            end
/* evaluation: one sprite per dot */
            if (in_ev && !ev_done)
            begin
                if (ev_cnt != SPR_MAX)
                begin
/* on this line: it gets the next unit */
                    if (ev_in)
                    begin
                        sec_idx[ev_cnt[2:0]] <= ev_n[5:0];
                        ev_cnt <= ev_cnt + 4'd1;
                    end
                end
/* eight found: the real chip goes on with a wrong byte offset and may set the overflow flag */
                else if (ev_in)
                begin
                    ovf     <= 1'b1;
                    ev_done <= 1'b1;
                end
                else
                begin
/* the wrong byte offset of the real chip */
                    ev_m <= ev_m + 2'd1;
                end
/* the next sprite; the end of the table */
                ev_n <= ev_n + 7'd1;
                if (ev_n[5:0] == OAM_LAST)
                begin
                    ev_done <= 1'b1;
                end
            end
        end

/* ---- the end of a dot ---- */
        if (dot_end)
        begin
/* the counters */
            if (hc == H_LAST || (hc == H_SKIP && pre && odd && ren))
            begin
                hc <= 9'd0;
                if (pre)
                begin
/* a new frame */
                    vc  <= 9'd0;
                    odd <= !odd;
                end
                else
                begin
                    vc <= vc + 9'd1;
                end
            end
            else
            begin
/* the next dot */
                hc <= hc + 9'd1;
            end

/* the flags */
            if (vc == V_VBL && hc == 9'd0)
            begin
                if (!vbl_block)
                begin
                    vbl <= 1'b1;
                end
/* the block ends here */
                vbl_block <= 1'b0;
            end
            if (pre && hc == 9'd0)
            begin
                vbl   <= 1'b0;
/* sprite 0 hit and overflow */
                s0hit <= 1'b0;
                ovf   <= 1'b0;
            end
/* the frame is complete */
            if (vc == V_PIC && hc == 9'd0)
            begin
                px_eof <= 1'b1;
            end

/* the pixel */
            if (vis && in_pic)
            begin
                px_stb <= 1'b1;
                px_x   <= xpos;
/* its line, colour and emphasis */
                px_y   <= vc[7:0];
                px_c   <= mask[0] ? (pal_q & GREY_MASK) : pal_q;
                px_e   <= mask[7:5];
/* sprite 0 over the background */
                if (s0_line && sp0 && bgp != 2'b00 && xpos != 8'hFF)
                begin
                    s0hit <= 1'b1;
                end
            end

/* the sprite units count down to their column, then shift */
            if (rl && in_pic)
            begin
                for (i = 0; i < SPRITES; i = i + 1)
                begin
                    if (sp_x[i] != 8'd0)
                    begin
/* not at its column yet */
                        sp_x[i] <= sp_x[i] - 8'd1;
                    end
                    else
                    begin
                        sp_lo[i] <= {sp_lo[i][6:0], 1'b0};
                        sp_hi[i] <= {sp_hi[i][6:0], 1'b0};
                    end
                end
            end

/* the background */
            if (rl && in_bg)
            begin
/* ask for the tile row's two pattern bytes */
                if (sub == 3'd0)
                begin
                    pt_addr <= {ctrl[4], nt_byte, 1'b0, v[14:12]};
                    pt_tgl  <= !pt_tgl;
                end
/* shift; at the end of a group the next tile enters and v goes to the next column */
                at_lo <= {at_lo[6:0], at_lat[0]};
                at_hi <= {at_hi[6:0], at_lat[1]};
                if (sub == SUB_LAST)
                begin
/* both planes of the next tile */
                    bg_lo  <= {bg_lo[14:7], pt_q[7:0]};
                    bg_hi  <= {bg_hi[14:7], pt_q[15:8]};
                    at_lat <= at_bits;
/* the next column */
                    v      <= v_incx;
                end
                else
                begin
                    bg_lo <= {bg_lo[14:0], 1'b0};
                    bg_hi <= {bg_hi[14:0], 1'b0};
                end
            end

/* v: the next row after the last pixel, then the horizontal part of t */
            if (rl && hc == H_PIC_LAST)
            begin
                v[14:12] <= v[14:12] + 3'd1;
                if (fy_max)
                begin
/* the next row of tiles */
                    v[9:5] <= cy_nxt;
                    if (v[9:5] == ROW_LAST)
                    begin
                        v[11] <= !v[11];
                    end
                end
            end
/* the horizontal part of t */
            if (rl && hc == H_SPR_FIRST)
            begin
                v[10]  <= t[10];
                v[4:0] <= t[4:0];
            end
/* the vertical part of t before a frame */
            if (ren && pre && hc >= H_VCOPY_FIRST && hc <= H_VCOPY_LAST)
            begin
                v[14:11] <= t[14:11];
                v[9:5]   <= t[9:5];
            end

/* the sprites of the next line */
            if (hc == H_EVAL_START)
            begin
                ev_n    <= 7'd0;
                ev_m    <= 2'd0;
/* nothing found yet */
                ev_done <= 1'b0;
                ev_cnt  <= 4'd0;
            end
            if (rl && in_sp)
            begin
/* the real chip's sprite address is 0 through these dots: a copy that follows starts at sprite 0 */
                oamaddr <= 8'd0;
/* sprite 0 is among them */
                if (hc == H_SPR_FIRST)
                begin
                    s0_line <= ev_cnt != 4'd0 && sec_idx[0] == 6'd0;
                end
/* ask for its pattern bytes */
                if (sub == SUB_SPR_REQ && f_valid)
                begin
                    pt_addr <= f_addr;
                    pt_tgl  <= !pt_tgl;
                end
/* the unit is loaded */
                if (sub == SUB_LAST)
                begin
                    sp_lo[slot] <= !f_valid ? 8'd0 : f_attr[6] ? rev8(pt_q[7:0])  : pt_q[7:0];
                    sp_hi[slot] <= !f_valid ? 8'd0 : f_attr[6] ? rev8(pt_q[15:8]) : pt_q[15:8];
/* its column and attributes */
                    sp_x[slot]  <= f_x;
                    sp_at[slot] <= {f_attr[5], f_attr[1:0]};
                end
            end

/* the CPU's memory accesses of this dot are done */
            oam_cpu_q <= oam_q;
            if (c_rd_nt)
            begin
                rd_buf <= nt_q;
            end
/* a pattern byte the system read */
            if (c_rd_chr)
            begin
                rd_buf <= chr_q;
            end
            if (c_wr_oam)
            begin
/* the sprite address steps after a write */
                oamaddr <= oamaddr + 8'd1;
            end
            c_wr_nt  <= 1'b0;
            c_rd_nt  <= 1'b0;
/* no read pending */
            c_rd_chr <= 1'b0;
            c_wr_oam <= 1'b0;
        end

/* ---- the CPU writes a register ---- */
        if (reg_we)
        begin
            ob <= reg_d;
            case (reg_a)
/* control: NMI, sprite size, tables, address step, the name table */
                3'd0:
                begin
                    ctrl     <= reg_d;
                    t[11:10] <= reg_d[1:0];
                end
/* the mask: what is shown */
                3'd1: mask <= reg_d;
                R_OAMADDR: oamaddr <= reg_d;
/* a sprite byte */
                R_OAMDATA:
                begin
                    c_wr_oam <= 1'b1;
                    c_data   <= oamaddr[1:0] == 2'b10 ? (reg_d & ATTR_MASK) : reg_d;
                end
/* scroll: x first, then y */
                R_SCROLL:
                begin
                    if (!w)
                    begin
                        t[4:0] <= reg_d[7:3];
/* fine x */
                        fx     <= reg_d[2:0];
                    end
                    else
                    begin
                        t[14:12] <= reg_d[2:0];
                        t[9:5]   <= reg_d[7:3];
                    end
/* the other half next */
                    w <= !w;
                end
/* address: high byte first; the second write loads v */
                R_ADDR:
                begin
                    if (!w)
                    begin
                        t[14:8] <= {1'b0, reg_d[5:0]};
                    end
                    else
                    begin
/* the low byte: v is loaded */
                        t[7:0] <= reg_d;
                        v      <= {t[14:8], reg_d};
                    end
                    w <= !w;
                end
/* data: palette, name table (pattern memory is the system's) */
                R_DATA:
                begin
                    if (v_pal)
                    begin
                        pal[pal_slot(v[4:0])] <= reg_d[5:0];
                    end
/* a name table byte */
                    else if (v[13])
                    begin
                        c_wr_nt <= 1'b1;
                        c_addr  <= v[11:0];
/* its value */
                        c_data  <= reg_d;
                    end
                    v <= v_step;
                end
                default: ;
            endcase
        end

/* ---- the CPU reads a register ---- */
        if (reg_re)
        begin
            case (reg_a)
                R_STATUS:
                begin
/* the three flags above the bus's last value */
                    reg_q <= {vbl, s0hit, ovf, ob[STATUS_OPEN-1:0]};
                    ob[7:STATUS_OPEN] <= {vbl, s0hit, ovf};
                    vbl   <= 1'b0;
/* the write toggle starts again */
                    w     <= 1'b0;
/* read in the dot that sets the flag: it is not set in this frame */
                    if (vc == V_VBL && hc == 9'd0)
                    begin
                        vbl_block <= 1'b1;
                    end
                end
                R_OAMDATA:
                begin
/* the sprite byte */
                    reg_q <= oam_cpu_q;
                    ob    <= oam_cpu_q;
                end
/* data: the palette at once, everything else through the buffer */
                R_DATA:
                begin
                    if (v_pal)
                    begin
                        reg_q <= {ob[7:6], pal_q};
/* the bus keeps it */
                        ob[5:0] <= pal_q;
                    end
                    else
                    begin
                        reg_q <= rd_buf;
                        ob    <= rd_buf;
                    end
/* a name table byte goes into the buffer */
                    if (v[13])
                    begin
                        c_rd_nt <= 1'b1;
                        c_addr  <= v[11:0];
                    end
                    else
                    begin
/* a pattern byte: the system reads it */
                        c_rd_chr <= 1'b1;
                    end
                    v <= v_step;
                end
                default: reg_q <= ob;
            endcase
        end
    end

endmodule

/* other files keep the default net type */
`default_nettype wire
