// esp32_v2.ino - the LSpectrum system controller on the ESP32: SD tape loader + Bluetooth audio.
//
// Board : ESP32-WROOM-32 dev board (CP2102, Type-C). Arduino core esp32 3.3.x,
//         board "ESP32 Dev Module". Needs Classic BT (original ESP32 only).
// Lib   : ESP32-A2DP by Phil Schatzmann, v1.8.11; AAudioLinkFix (libraries/, copy it into the
//         sketchbook's libraries folder).
//
// SD tape loader (src/): owns the SD card (VSPI) and runs the browser, TAP/TZX playback,
// recording, .z80 load/save and the F3 menu as a task, driving the FPGA's loader hardware over
// the SPI link (src/esp_hw.cpp, rtl/esp_link.v). It starts when the FPGA answers with the
// LSpectrum core ID.
//
// Bluetooth audio: an A2DP source (like a phone) that sends 44.1 kHz stereo to a BT
// speaker/headphones. Audio comes from the FPGA over I2S (the ESP32 is the I2S
// master: BCLK GPIO26, LRCK GPIO25 out, DATA GPIO22 in; rtl/bt_i2s.v),
// or from a built-in test tone ("src tone").
//
// Pairing: SSP devices (BT 2.1+, almost all) are accepted without a code. Legacy
// devices ask for a PIN: by default the common codes 0000, 1234, 8888, 1111 are
// tried in turn (one per connection attempt), or a fixed one is set with "pin".
//
// Control: line commands at 115200 baud on UART2 (RX GPIO27, TX GPIO21; GPIO16/17 are the
// WROVER module's PSRAM), which the
// FPGA's UART connects to the loader's F3 menu (src/bt.cpp), and on USB (Serial) for
// debugging; both take the same commands.
// Replies go to the port the command came from and start with "OK" or "ERR";
// unsolicited events go to both ports and start with "EV". "help" lists them.
// Input lines may end in CR, LF or CR+LF; every output line ends in CR+LF.

#include <AAudioLinkFix.h>   // links with -Wl,--wrap=bta_av_co_audio_set_codec
#include <BluetoothA2DPSource.h>
#include <Preferences.h>
#include <driver/gpio.h>
#include <driver/i2s_std.h>
#include <math.h>
#include "src/loader.h"

// ---------------------------------------------------------------- ESP-IDF 5.5 fix
// When the speaker opens the A2DP stream itself (Bose headphones reconnect to
// their last source by themselves, or answer our connect with their own) and
// configures it with the standard SBC setup, Bluedroid never asks for the sink's
// capabilities. bta_av_co_audio_set_codec() then fails ("peer supports no codec"),
// btc_a2dp_source_setup_codec() skips the encoder setup, and the first stream
// start divides by the encoder's 0 blocks in SBC_Encoder_Init. That
// configuration is Bluedroid's own default (44.1 kHz, joint stereo, 16 blocks,
// 8 subbands), so report success while a link is open: the encoder and the PCM
// feeding are then set up with it (bitpool range from the peer's set-config).
// The caller ignores *status.
static volatile uint32_t codec_forced;   // times the fix was needed

extern "C" uint8_t __real_bta_av_co_audio_set_codec(const void *feeding, void *status);
extern "C" uint8_t btc_av_is_connected(void);

extern "C" uint8_t __wrap_bta_av_co_audio_set_codec(const void *feeding, void *status) {
  if (__real_bta_av_co_audio_set_codec(feeding, status)) return 1;
  if (!btc_av_is_connected()) return 0;
  codec_forced = codec_forced + 1;
  return 1;
}

// SBC bitpool cap (`bitpool <n>`, 0 = none = default). btc_a2dp_source_encoder_update() takes the
// sink's bitpool range from bta_av_co_get_remote_bitpool_pref() when that returns TRUE (the sink
// sent SET CONFIG), otherwise the current SBC configuration's range. With a cap set, the wrapper
// always returns TRUE with the range capped (the configuration's range when the sink gave none), so
// the encoder sends a lower bitrate: bitpool 53 (Bluedroid's default) = 328 kbit/s, 35 = 229 kbit/s,
// 29 = 196 kbit/s at 44.1 kHz joint stereo. Stored; used from the next stream start (reconnect).
// History: 29 was the default from 2026-11-05 to 2026-11-10, when some connections carried only 2/3
// of the audio. The cause was not the radio but the internal heap (see "Media packets" below): with
// a smaller bitpool one packet per tick was enough.
static volatile uint8_t bitpool_cap = 0;
static volatile uint8_t bp_peer_min, bp_peer_max, bp_max;   // range from the codec config, max used
static volatile uint32_t bp_calls;

static volatile bool bp_from_peer;   // the last range came from the sink's SET CONFIG

extern "C" uint8_t __real_bta_av_co_get_remote_bitpool_pref(uint8_t *min, uint8_t *max);
// tA2D_SBC_CIE (stack/a2d_sbc.h): samp_freq, ch_mode, block_len, num_subbands, alloc_mthd,
// max_bitpool, min_bitpool, all UINT8
extern "C" uint8_t bta_av_co_audio_get_sbc_config(uint8_t *sbc_cie, uint16_t *minmtu);

extern "C" uint8_t __wrap_bta_av_co_get_remote_bitpool_pref(uint8_t *min, uint8_t *max) {
  uint8_t r = __real_bta_av_co_get_remote_bitpool_pref(min, max);
  bp_from_peer = r;
  if (!r) {
    uint8_t cie[8] = {0};
    uint16_t mtu;
    bta_av_co_audio_get_sbc_config(cie, &mtu);
    if (cie[6] < 2 || cie[5] > 250 || cie[6] > cie[5]) return r;   // not a sane range: leave it alone
    *max = cie[5];
    *min = cie[6];
  }
  bp_peer_min = *min;
  bp_peer_max = *max;
  uint8_t cap = bitpool_cap;
  if (cap && *max > cap) *max = cap;
  if (*min > *max) *min = *max;
  bp_max = *max;
  bp_calls = bp_calls + 1;
  return bitpool_cap ? 1 : r;
}

// Link role and power mode of the open link, shown by `status` / `rates` (diagnosis; Bluedroid
// accepts an incoming connection as slave and never asks for a switch, the audio does not depend on it).
extern "C" int BTM_GetRole(uint8_t *bda, uint8_t *role);               // 0 = BTM_SUCCESS
extern "C" int BTM_ReadPowerMode(uint8_t *bda, uint8_t *mode);         // 0 active, 2 sniff
static uint8_t link_role = 0xff, link_mode = 0xff;   // 0 master, 1 slave; 0xff = no link
static uint32_t role_changes;

static const char *role_name(uint8_t r) { return r == 0 ? "master" : r == 1 ? "slave" : "-"; }
static const char *mode_name(uint8_t m) {
  return m == 0 ? "active" : m == 1 ? "hold" : m == 2 ? "sniff" : m == 3 ? "park" : "-";
}

// Media packets. Bluedroid builds every A2DP media packet in a 4112-byte buffer from the internal
// heap (osi_malloc(BTC_MEDIA_AA_BUF_SIZE) in btc_media_aa_prep_sbc_2_send) and fills it up to the
// sink's MTU: 7 SBC frames at bitpool 53 with an MTU of 883, so a 30 ms tick (10.3 frames) needs two
// packets. When the second allocation fails the function returns without a word: those frames are
// never read, the sink gets 2/3 of the audio (29,867 Hz pulled; choppy, "sped up"), and with less
// memory still nothing at all (connected, silent). Found 2026-11-10; the heap then had 13-18 KB free
// while streaming. Keep the internal heap well above 20 KB while streaming (`status`, heap line).
// Counted where BTA hands a packet to AVDTP: packets, SBC frames (layer_specific) and bytes.
struct BtHdr { uint16_t event, len, offset, layer_specific; };
static volatile uint32_t pk_n, pk_frames, pk_err;
static volatile uint16_t pk_max_len, pk_max_frames;
static uint32_t meas_pk_hz, meas_pkfr_hz;
extern "C" uint16_t __real_AVDT_WriteReqOpt(uint8_t handle, void *pkt, uint32_t ts, uint8_t m_pt, uint8_t opt);
extern "C" uint16_t __wrap_AVDT_WriteReqOpt(uint8_t handle, void *pkt, uint32_t ts, uint8_t m_pt, uint8_t opt) {
  const BtHdr *h = (const BtHdr *)pkt;
  uint16_t len = h->len, fr = h->layer_specific & 0x0f;   // read before the stack takes the buffer
  uint16_t r = __real_AVDT_WriteReqOpt(handle, pkt, ts, m_pt, opt);
  pk_n = pk_n + 1;
  pk_frames = pk_frames + fr;
  if (len > pk_max_len) pk_max_len = len;
  if (fr > pk_max_frames) pk_max_frames = fr;
  if (r) pk_err = pk_err + 1;
  return r;
}

// More of the same: how many buffers L2CAP still holds for the media channel when BTA asks (it sends
// a new packet only below a limit), packets BTA dropped, and the number of ACL links the stack counts.
static volatile uint16_t l2c_last, l2c_max;
static volatile uint32_t l2c_calls, co_drops;
extern "C" uint16_t BTM_GetNumAclLinks(void);
extern "C" uint16_t __real_L2CA_FlushChannel(uint16_t lcid, uint16_t num);
extern "C" uint16_t __wrap_L2CA_FlushChannel(uint16_t lcid, uint16_t num) {
  uint16_t r = __real_L2CA_FlushChannel(lcid, num);
  if (num == 0) {                      // L2CAP_FLUSH_CHANS_GET: a query
    l2c_last = r;
    if (r > l2c_max) l2c_max = r;
    l2c_calls = l2c_calls + 1;
  }
  return r;
}
extern "C" void __real_bta_av_co_audio_drop(uint8_t hndl);
extern "C" void __wrap_bta_av_co_audio_drop(uint8_t hndl) {
  co_drops = co_drops + 1;
  __real_bta_av_co_audio_drop(hndl);
}

static const uint32_t SAMPLE_RATE = 44100;
// I/O board revision 2: ESP32-WROVER-E-N16R8, its PSRAM on GPIO16 / GPIO17, so the control UART
// is on GPIO27 (RX2 <- FPGA BT_TX) / GPIO21 (TX2 -> FPGA BT_RX). Revision 1 (DevKit) = esp32_v1.
#ifndef BOARD_HAS_PSRAM
#error "esp32_v2 is for the WROVER module: build with PSRAM enabled (FQBN esp32:esp32:esp32:PSRAM=enabled,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB)"
#endif
static const int UART2_RX = 27;
static const int UART2_TX = 21;
static const int I2S_BCLK = 26;
static const int I2S_LRCK = 25;
static const int I2S_DIN = 22;
static const int MAX_DEVS = 16;

static const char *const AUTO_PINS[] = {"0000", "1234", "8888", "1111"};
static const int N_AUTO_PINS = sizeof AUTO_PINS / sizeof AUTO_PINS[0];

Preferences prefs;

// ---------------------------------------------------------------- output

static void event(const char *fmt, ...) {
  char buf[128];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  Serial.printf("EV %s\r\n", buf);
  Serial2.printf("EV %s\r\n", buf);
}

static void mac_str(const uint8_t *m, char *out) {
  sprintf(out, "%02x:%02x:%02x:%02x:%02x:%02x", m[0], m[1], m[2], m[3], m[4], m[5]);
}

static bool parse_mac(const char *s, uint8_t *m) {
  unsigned v[6];
  if (strlen(s) != 17 ||
      sscanf(s, "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6)
    return false;
  for (int i = 0; i < 6; i++) m[i] = (uint8_t)v[i];
  return true;
}

// ---------------------------------------------------------------- audio source
// get_frames() runs in the BT task; loop() only writes the volatile settings.

static volatile bool src_i2s;         // false = test tone
static volatile bool muted;
static i2s_chan_handle_t i2s_rx;
static volatile uint32_t i2s_underruns;
// The I2S clock (APLL, 44.1 kHz) and the A2DP stack's sending timer are different clocks: a few
// ppm apart, the DMA backlog drifts. Left alone it fills the buffers and the driver overwrites one
// (a 5.8 ms skip forward, heard as a short "speed-up"), or runs dry (silence).
// The stack takes the audio in bursts: every 30 ms tick about 1,300-1,400 frames within a few ms. So
// the backlog is looked at once per tick, at the first read of the burst (its highest point), and
// kept in [BACKLOG_LO, BACKLOG_HI] by dropping or repeating one sample frame in that tick (at most
// 33 frames/s = 750 ppm). The lowest point is then about 400 frames or more, the highest stays 3
// buffers below the 12 the DMA has. Far outside (stream start, a hiccup): one jump back to
// BACKLOG_MID, by throwing frames away or by a tick or two of silence.
static volatile uint32_t i2s_rx_frames;   // frames the DMA delivered (ISR)
static uint32_t i2s_rd_frames;            // frames read by get_frames
static volatile uint32_t i2s_overflows;   // DMA buffers overwritten (ISR)
static uint32_t i2s_drops, i2s_dups;      // drift corrections
static uint32_t i2s_resyncs;              // jumps back to BACKLOG_MID
static const int DMA_BUFS = 12, DMA_LEN = 256;                                     // 12 x 5.8 ms
static const int32_t BACKLOG_LO = 1792, BACKLOG_MID = 2048, BACKLOG_HI = 2304;   // frames at the start of a tick
// The A2DP stack asks for audio in steady steps (~10-20 ms). A step much later than that means the
// sending side was held up (the speaker's buffer can run dry: a short gap); the radio side shows no
// late step. Counted while connected; the F3 menu shows both counters.
static volatile uint32_t cb_late;      // steps more than LATE_US after the one before
static volatile uint32_t cb_max_us;    // longest step distance (while connected)
static int64_t cb_last;
static const int64_t LATE_US = 60000;
static volatile int32_t i2s_peak;     // largest |sample| since the last status
// Rate check (diagnosis, measures only): the I2S input and the A2DP stack must run at the same
// sample rate. Seen on hardware (2026-11-05, both speakers, some starts only): the DMA lost about
// every 4th buffer, ~14,000 frames/s more delivered than pulled, far beyond what the drift fix above
// can follow. loop() measures both rates every 2 s and keeps a history (`rates` command): the first
// measurements of every stream and every measurement that differs by more than 2 % from the last one
// kept. Changing the I2S clock automatically was tried and is wrong: when I2S delivers less, the
// A2DP pull rate drops too (get_frames waits for data), so the two rates are not independent.
static volatile uint32_t i2s_gross;     // frames the DMA delivered, overwritten ones included (ISR)
static volatile uint32_t a2dp_req;      // frames get_frames was asked for
static uint32_t meas_i2s_hz, meas_a2dp_hz;   // last measurement (loop)
static volatile uint8_t  sbc_cfg;       // first SBC byte of the last ESP_A2D_AUDIO_CFG_EVT (0 = none)
static volatile uint32_t cfg_events;
static volatile int8_t link_rssi;     // ESP_BT_GAP_READ_RSSI_DELTA_EVT: 0 = in the golden range, < 0 weaker
static volatile uint32_t rssi_reads;
struct RateLog { uint32_t ms, i2s_hz, a2dp_hz, ovf, fix; int8_t rssi; uint8_t bitpool, role, mode; };
static RateLog rate_log[24];            // ring
static uint32_t rate_log_n;             // entries written

static uint32_t sbc_hz(uint8_t b) {     // A2DP SBC codec byte 0: sampling frequency in bits 7..4
  return b & 0x80 ? 16000 : b & 0x40 ? 32000 : b & 0x20 ? 44100 : b & 0x10 ? 48000 : 0;
}

struct SineTab {                      // built by the compiler: in flash, not in RAM
  int16_t v[1024];
  constexpr SineTab() : v{} {
    for (int i = 0; i < 1024; i++) v[i] = (int16_t)__builtin_lround(32767.0 * __builtin_sin(i * 2.0 * 3.14159265358979323846 / 1024));
  }
};
static constexpr SineTab sine_tab_c;
static const int16_t *const sine_tab = sine_tab_c.v;
static volatile uint32_t phase_inc;   // phase step per sample, 2^32 = one period
static volatile int32_t amp;          // 0..32767
static volatile bool square_wave;
static uint32_t phase;
static uint32_t tone_hz, level_pct, volume;

static void set_tone(uint32_t hz) {
  tone_hz = hz;
  phase_inc = (uint32_t)(((uint64_t)hz << 32) / SAMPLE_RATE);
}

static void set_level(uint32_t pct) {
  level_pct = pct;
  amp = (int32_t)(pct * 32767 / 100);
}

static void tone_frames(Frame *f, int32_t n) {
  uint32_t inc = phase_inc;
  int32_t a = amp;
  bool sq = square_wave;
  for (int32_t i = 0; i < n; i++) {
    int32_t s = 0;
    if (inc) {
      s = sq ? ((phase & 0x80000000u) ? -32767 : 32767) : sine_tab[phase >> 22];
      s = (s * a) >> 15;
      phase += inc;
    }
    f[i].channel1 = f[i].channel2 = (int16_t)s;
  }
}

static void i2s_discard(int32_t frames) {
  Frame junk[64];
  while (frames > 0) {
    size_t want = (size_t)(frames < 64 ? frames : 64) * sizeof(Frame), r = 0;
    i2s_channel_read(i2s_rx, junk, want, &r, 0);
    i2s_rd_frames += r / sizeof(Frame);
    frames -= 64;
    if (r < want) break;
  }
}

// I2S and A2DP both run from the ESP32's clocks, so on average the data is there;
// a short wait (at most ~8 ms) covers the DMA buffer granularity, silence beyond.
// first = the first read of a tick's burst.
static void i2s_frames(Frame *f, int32_t n, bool first) {
  static bool filling;                 // silence until the backlog is back at BACKLOG_MID
  uint8_t *p = (uint8_t *)f;
  int adj = 0;
  if (first) {
    int32_t backlog = (int32_t)(i2s_rx_frames - i2s_rd_frames);
    if (backlog > BACKLOG_HI + 512) {                  // far too much: throw the excess away
      i2s_discard(backlog - BACKLOG_MID);
      i2s_resyncs++;
    } else if (backlog < BACKLOG_LO - 512) {           // not enough for this burst: let it fill
      if (!filling) i2s_resyncs++;
      filling = true;
    } else if (filling) {
      if (backlog >= BACKLOG_MID - 256) filling = false;
    } else if (n > 2) {
      adj = backlog > BACKLOG_HI ? 1 : backlog < BACKLOG_LO ? -1 : 0;
    }
  }
  if (filling) {
    memset(p, 0, (size_t)n * sizeof(Frame));
    return;
  }
  size_t want = (size_t)(n - (adj < 0 ? 1 : 0)) * sizeof(Frame), got = 0;
  for (int tries = 0; got < want && tries < 4; tries++) {
    size_t r = 0;
    i2s_channel_read(i2s_rx, p + got, want - got, &r, 2);
    got += r;
  }
  i2s_rd_frames += got / sizeof(Frame);
  if (got < want) {
    memset(p + got, 0, want - got);
    i2s_underruns = i2s_underruns + 1;
  } else if (adj > 0) {
    Frame extra;
    size_t r = 0;
    i2s_channel_read(i2s_rx, &extra, sizeof extra, &r, 0);   // dropped
    if (r == sizeof extra) { i2s_rd_frames += 1; i2s_drops++; }
  } else if (adj < 0) {
    f[n - 1] = f[n - 2];                                       // repeated
    i2s_dups++;
  }
  int32_t pk = i2s_peak;
  for (int32_t i = 0; i < n; i++) {
    int32_t a = abs(f[i].channel1);
    if (a > pk) pk = a;
  }
  i2s_peak = pk;
}

static int32_t get_frames(Frame *f, int32_t n) {
  int64_t now = esp_timer_get_time();
  if (cb_last && now - cb_last < 2000000) {        // longer = the stream had stopped (not a gap)
    uint32_t d = (uint32_t)(now - cb_last);
    if (d > cb_max_us) cb_max_us = d;
    if (d > LATE_US) cb_late = cb_late + 1;
  }
  bool first = !cb_last || now - cb_last > 12000;   // the calls of one tick follow each other within a few ms
  cb_last = now;
  a2dp_req = a2dp_req + n;
  if (src_i2s) i2s_frames(f, n, first);
  else tone_frames(f, n);
  if (muted) memset(f, 0, (size_t)n * sizeof(Frame));
  return n;
}

static bool IRAM_ATTR i2s_on_recv(i2s_chan_handle_t, i2s_event_data_t *e, void *) {
  i2s_rx_frames = i2s_rx_frames + e->size / sizeof(Frame);
  i2s_gross = i2s_gross + e->size / sizeof(Frame);
  return false;
}

static bool IRAM_ATTR i2s_on_ovf(i2s_chan_handle_t, i2s_event_data_t *e, void *) {
  i2s_overflows = i2s_overflows + 1;
  i2s_rx_frames = i2s_rx_frames - (e && e->size ? e->size : DMA_LEN * sizeof(Frame)) / sizeof(Frame);   // that buffer is gone
  return false;
}

static void i2s_start() {
  i2s_chan_config_t chan = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
  chan.dma_desc_num = DMA_BUFS;
  chan.dma_frame_num = DMA_LEN;
  ESP_ERROR_CHECK(i2s_new_channel(&chan, nullptr, &i2s_rx));
  i2s_std_config_t cfg = {
      .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE),
      .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO),
      .gpio_cfg = {
          .mclk = I2S_GPIO_UNUSED,
          .bclk = (gpio_num_t)I2S_BCLK,
          .ws = (gpio_num_t)I2S_LRCK,
          .dout = I2S_GPIO_UNUSED,
          .din = (gpio_num_t)I2S_DIN,
          .invert_flags = {false, false, false},
      },
  };
  cfg.clk_cfg.clk_src = I2S_CLK_SRC_APLL;   // exact 44.1 kHz
  ESP_ERROR_CHECK(i2s_channel_init_std_mode(i2s_rx, &cfg));
  i2s_event_callbacks_t cbs = {};
  cbs.on_recv = i2s_on_recv;
  cbs.on_recv_q_ovf = i2s_on_ovf;
  ESP_ERROR_CHECK(i2s_channel_register_event_callback(i2s_rx, &cbs, nullptr));
  gpio_pulldown_en((gpio_num_t)I2S_DIN);    // silence when the FPGA is not connected
  ESP_ERROR_CHECK(i2s_channel_enable(i2s_rx));
}

// ---------------------------------------------------------------- devices found
// on_found() runs in the BT task during discovery; loop() prints new entries.

struct Dev {
  uint8_t mac[6];
  char name[32];
  int rssi;
  bool reported;
};

static Dev devs[MAX_DEVS];
static int ndevs;
static portMUX_TYPE devs_mux = portMUX_INITIALIZER_UNLOCKED;

static char target[40];              // MAC "aa:bb:cc:dd:ee:ff" or exact device name
static volatile bool want_connect;   // connect to target when discovery sees it
static char peer_name[32];

static bool is_target(const char *name, const uint8_t *mac) {
  if (!target[0]) return false;
  uint8_t tm[6];
  if (parse_mac(target, tm)) return memcmp(tm, mac, 6) == 0;
  return name[0] && strcasecmp(target, name) == 0;
}

static bool dev_known(const uint8_t *mac) {
  bool known = false;
  portENTER_CRITICAL(&devs_mux);
  for (int i = 0; i < ndevs; i++)
    if (memcmp(devs[i].mac, mac, 6) == 0) known = true;
  portEXIT_CRITICAL(&devs_mux);
  return known;
}

// Records a device seen by discovery; true = it is the target, connect to it.
// A device without a name in the inquiry result gets one later from the name
// request (or never): it is then reported again.
static bool on_found(const char *name, const uint8_t *mac, int rssi) {
  portENTER_CRITICAL(&devs_mux);
  int i;
  for (i = 0; i < ndevs; i++)
    if (memcmp(devs[i].mac, mac, 6) == 0) break;
  if (i == ndevs && ndevs < MAX_DEVS) {
    ndevs++;
    memcpy(devs[i].mac, mac, 6);
    devs[i].name[0] = 0;
    devs[i].rssi = -129;
    devs[i].reported = false;
  }
  if (i < ndevs) {
    if (name[0] && strcmp(devs[i].name, name) != 0) {
      strlcpy(devs[i].name, name, sizeof devs[i].name);
      devs[i].reported = false;
    }
    if (rssi != -129) devs[i].rssi = rssi;
  }
  portEXIT_CRITICAL(&devs_mux);

  bool hit = want_connect && is_target(name, mac);
  if (hit && name[0]) strlcpy(peer_name, name, sizeof peer_name);
  return hit;
}

// ---------------------------------------------------------------- A2DP source
// Adds to the library: pairing with legacy PIN devices (and events about it),
// discovery of devices that only give their name by name request (BT 2.0, the
// PIN ones), no discovery while connected, and the SBC encoder fix below.

static char pin_fixed[17];           // "" = auto (AUTO_PINS)
static volatile int pin_try;         // index into AUTO_PINS
static volatile bool link_up;

// Audio stream state, written in the BT task, reported by loop()
static volatile int audio_state = -1;      // last ESP_A2D_AUDIO_STATE_EVT state (-1 = none yet)
static volatile uint32_t audio_events;     // ESP_A2D_AUDIO_STATE_EVT count
static volatile uint32_t media_restarts;   // streams started again by us (kick_media)
static uint32_t relinks;                   // links dropped and made again because no stream came back

class ZxA2DP : public BluetoothA2DPSource {
 public:
  // The library (1.8.11) starts the stream once per connection: a sink that suspends it (Bose
  // headphones did, 1-2 s after connecting during a tape load) leaves the link "connected" with
  // no audio pulled, for good. Its media state back to idle makes the heart beat (1 s) check and
  // start the stream again. Called by loop() when no audio was asked for 3 s while connected.
  bool kick_media() {
    if (s_media_state != 2) return false;   // APP_AV_MEDIA_STATE_STARTED (not starting / stopping)
    s_media_state = 0;                     // APP_AV_MEDIA_STATE_IDLE
    media_restarts = media_restarts + 1;
    return true;
  }
  int media_state() { return s_media_state; }

  // BR/EDR transmit power: the controller's default range is 0..+3 dBm; +9 dBm is the ESP32's
  // maximum (2026-11-05, weak link: RSSI delta about -20). ESP-IDF wants it after the controller is
  // enabled and before any RF use, which is exactly the library's bt_start() (then Bluedroid starts).
  bool bt_start() override {
    bool ok = BluetoothA2DPSource::bt_start();
    if (ok) tx_power_err = esp_bredr_tx_power_set(ESP_PWR_LVL_N0, ESP_PWR_LVL_P9);
    return ok;
  }
  static esp_err_t tx_power_err;

  // set_pin_code() copies with strcpy into a 16-byte array: a 16-digit PIN overflows
  void use_pin(const char *pin) {
    size_t n = strlen(pin);
    if (n > ESP_BT_PIN_CODE_LEN) n = ESP_BT_PIN_CODE_LEN;
    memset(pin_code, 0, sizeof pin_code);
    memcpy(pin_code, pin, n);
    pin_code_len = n;
    pin_type = ESP_BT_PIN_TYPE_VARIABLE;
  }

 protected:
  bool pin_asked = false;

  void app_gap_callback(esp_bt_gap_cb_event_t event_id, esp_bt_gap_cb_param_t *param) override {
    switch (event_id) {
      case ESP_BT_GAP_PIN_REQ_EVT: {
        char pin[17];
        strlcpy(pin, pin_fixed[0] ? pin_fixed : AUTO_PINS[pin_try % N_AUTO_PINS], sizeof pin);
        if (param->pin_req.min_16_digit)          // pad to 16 digits with zeros
          while (strlen(pin) < 16) strcat(pin, "0");
        use_pin(pin);
        pin_asked = true;
        event("pairing pin %s", pin);
        break;                                     // the library replies with pin_code
      }
      case ESP_BT_GAP_CFM_REQ_EVT:
        event("pairing confirm %06u (accepted)", (unsigned)param->cfm_req.num_val);
        break;
      case ESP_BT_GAP_KEY_NOTIF_EVT:
        event("pairing passkey %06u", (unsigned)param->key_notif.passkey);
        break;
      case ESP_BT_GAP_AUTH_CMPL_EVT:
        if (param->auth_cmpl.stat == ESP_BT_STATUS_SUCCESS) {
          event("paired %s", (const char *)param->auth_cmpl.device_name);
        } else {
          event("pairing failed (status %d)", param->auth_cmpl.stat);
          if (pin_asked && !pin_fixed[0]) {
            pin_try = (pin_try + 1) % N_AUTO_PINS;
            event("pairing next try with pin %s", AUTO_PINS[pin_try]);
          }
        }
        pin_asked = false;
        break;
      case ESP_BT_GAP_READ_RSSI_DELTA_EVT:
        if (param->read_rssi_delta.stat == ESP_BT_STATUS_SUCCESS) {
          link_rssi = param->read_rssi_delta.rssi_delta;
          rssi_reads = rssi_reads + 1;
        }
        break;
      case ESP_BT_GAP_DISC_STATE_CHANGED_EVT:
        // The library restarts discovery whenever it stops without a find, even
        // while connected; inquiry during streaming costs radio time.
        if (link_up && param->disc_st_chg.state == ESP_BT_GAP_DISCOVERY_STOPPED) {
          discovery_active = false;
          return;
        }
        break;
      default:
        break;
    }
    BluetoothA2DPSource::app_gap_callback(event_id, param);
  }

  void app_a2d_callback(esp_a2d_cb_event_t event_id, esp_a2d_cb_param_t *param) override {
    if (event_id == ESP_A2D_AUDIO_STATE_EVT) {
      audio_state = param->audio_stat.state;
      audio_events = audio_events + 1;
    }
    if (event_id == ESP_A2D_AUDIO_CFG_EVT) {   // the codec set up for this connection
      sbc_cfg = ((const uint8_t *)&param->audio_cfg.mcc.cie)[0];
      cfg_events = cfg_events + 1;
    }
    if (event_id == ESP_A2D_CONNECTION_STATE_EVT) {
      if (param->conn_stat.state == ESP_A2D_CONNECTION_STATE_CONNECTED) {
        link_up = true;
        if (discovery_active) esp_bt_gap_cancel_discovery();
      } else if (param->conn_stat.state == ESP_A2D_CONNECTION_STATE_DISCONNECTED) {
        link_up = false;
      }
    }
    BluetoothA2DPSource::app_a2d_callback(event_id, param);
  }

  // As the library's, but a name may also come as BDNAME (name request result,
  // BT 2.0 devices have no EIR) or not at all (then connect by MAC).
  void filter_inquiry_scan_result(esp_bt_gap_cb_param_t *param) override {
    uint32_t cod = 0;
    bool has_cod = false;
    int rssi = -129;
    uint8_t *eir = nullptr;
    char name[ESP_BT_GAP_MAX_BDNAME_LEN + 1] = "";
    for (int i = 0; i < param->disc_res.num_prop; i++) {
      esp_bt_gap_dev_prop_t *p = param->disc_res.prop + i;
      switch (p->type) {
        case ESP_BT_GAP_DEV_PROP_COD:
          cod = *(uint32_t *)p->val;
          has_cod = true;
          break;
        case ESP_BT_GAP_DEV_PROP_RSSI:
          rssi = *(int8_t *)p->val;
          break;
        case ESP_BT_GAP_DEV_PROP_EIR:
          eir = (uint8_t *)p->val;
          break;
        case ESP_BT_GAP_DEV_PROP_BDNAME: {
          int n = p->len < ESP_BT_GAP_MAX_BDNAME_LEN ? p->len : ESP_BT_GAP_MAX_BDNAME_LEN;
          memcpy(name, p->val, n);
          name[n] = 0;
          break;
        }
        default:
          break;
      }
    }
    if (!name[0] && eir) get_name_from_eir(eir, (uint8_t *)name, nullptr);
    if (has_cod ? !(esp_bt_gap_is_valid_cod(cod) && is_valid_cod_service(cod))
                : !dev_known(param->disc_res.bda))
      return;                                      // not an audio device
    if (!on_found(name, param->disc_res.bda, rssi)) return;

    strlcpy((char *)s_peer_bdname, name, sizeof s_peer_bdname);
    s_a2d_state = APP_AV_STATE_DISCOVERED;
    memcpy(peer_bd_addr, param->disc_res.bda, ESP_BD_ADDR_LEN);
    set_last_connection(peer_bd_addr);
    esp_bt_gap_cancel_discovery();                 // the library connects when it stops
  }
};

ZxA2DP a2dp;
esp_err_t ZxA2DP::tx_power_err = ESP_FAIL;

// ---------------------------------------------------------------- status

static const char *conn_name(esp_a2d_connection_state_t s) {
  switch (s) {
    case ESP_A2D_CONNECTION_STATE_DISCONNECTED: return "disconnected";
    case ESP_A2D_CONNECTION_STATE_CONNECTING: return "connecting";
    case ESP_A2D_CONNECTION_STATE_CONNECTED: return "connected";
    case ESP_A2D_CONNECTION_STATE_DISCONNECTING: return "disconnecting";
    default: return "?";
  }
}

static void list_devs(Print &out) {
  Dev copy[MAX_DEVS];
  int n;
  portENTER_CRITICAL(&devs_mux);
  n = ndevs;
  memcpy(copy, devs, sizeof copy);
  portEXIT_CRITICAL(&devs_mux);
  out.printf("OK %d device(s)\r\n", n);
  for (int i = 0; i < n; i++) {
    char m[18];
    mac_str(copy[i].mac, m);
    out.printf("%2d %s %4d %s\r\n", i, m, copy[i].rssi, copy[i].name[0] ? copy[i].name : "(no name)");
  }
}

static void status(Print &out) {
  char m[18];
  mac_str(*a2dp.get_last_peer_address(), m);
  out.printf("OK state=%s peer=%s (%s) discovery=%s\r\n",
             conn_name(a2dp.get_connection_state()), m, peer_name[0] ? peer_name : "-",
             a2dp.is_discovery_active() ? "on" : "off");
  if (pin_fixed[0])
    out.printf("   target=%s autoconnect=%s pin=%s\r\n", target[0] ? target : "-",
               want_connect ? "on" : "off", pin_fixed);
  else
    out.printf("   target=%s autoconnect=%s pin=auto (next %s)\r\n", target[0] ? target : "-",
               want_connect ? "on" : "off", AUTO_PINS[pin_try]);
  out.printf("   src=%s vol=%u mute=%s i2s: peak=%d underruns=%u\r\n", src_i2s ? "i2s" : "tone",
             volume, muted ? "on" : "off", (int)i2s_peak, (unsigned)i2s_underruns);
  out.printf("   tone=%u Hz wave=%s level=%u%% codec-fix=%u\r\n", tone_hz,
             square_wave ? "square" : "sine", level_pct, (unsigned)codec_forced);
  out.printf("   audio steps: late=%u (> %u ms) longest=%u ms\r\n", (unsigned)cb_late,
             (unsigned)(LATE_US / 1000), (unsigned)(cb_max_us / 1000));
  out.printf("   stream: media state %d, audio state %d (%u events), restarts=%u, relinks=%u, last audio %ld ms ago\r\n",
             a2dp.media_state(), (int)audio_state, (unsigned)audio_events, (unsigned)media_restarts, (unsigned)relinks,
             cb_last ? (long)((esp_timer_get_time() - cb_last) / 1000) : -1L);
  out.printf("   i2s backlog=%d frames, overflows=%u, drift fixes: dropped=%u repeated=%u, resyncs=%u\r\n",
             (int)(i2s_rx_frames - i2s_rd_frames), (unsigned)i2s_overflows, (unsigned)i2s_drops, (unsigned)i2s_dups,
             (unsigned)i2s_resyncs);
  out.printf("   rates: i2s %u Hz, a2dp %u Hz, codec %u Hz (0x%02x, %u cfg events), history %u (`rates`)\r\n",
             (unsigned)meas_i2s_hz, (unsigned)meas_a2dp_hz, (unsigned)sbc_hz(sbc_cfg), (unsigned)sbc_cfg,
             (unsigned)cfg_events, (unsigned)rate_log_n);
  out.printf("   link: rssi delta %d (%u reads), bitpool %u..%u from the %s, cap %u -> max %u (%u calls)\r\n",
             (int)link_rssi, (unsigned)rssi_reads, (unsigned)bp_peer_min, (unsigned)bp_peer_max,
             bp_from_peer ? "sink" : "config",
             (unsigned)bitpool_cap, (unsigned)bp_max, (unsigned)bp_calls);
  {
    uint8_t cie[8] = {0};
    uint16_t mtu = 0;
    bta_av_co_audio_get_sbc_config(cie, &mtu);
    out.printf("   packets: %u/s with %u frames/s, largest %u frames / %u bytes, mtu %u, write errors %u, total %u\r\n",
               (unsigned)meas_pk_hz, (unsigned)meas_pkfr_hz, (unsigned)pk_max_frames, (unsigned)pk_max_len,
               (unsigned)mtu, (unsigned)pk_err, (unsigned)pk_n);
    pk_max_frames = 0;
    pk_max_len = 0;
    // Each media packet is a 4112-byte buffer from the internal heap (osi_malloc, BTC_MEDIA_AA_BUF_SIZE);
    // a tick that needs two packets needs two such blocks at once.
    out.printf("   heap: free %u, largest block %u, lowest free ever %u (internal RAM)\r\n",
               (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL),
               (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL),
               (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL));
    out.printf("   l2cap: %u buffers waiting (max %u, %u queries), dropped packets %u, acl links %u\r\n",
               (unsigned)l2c_last, (unsigned)l2c_max, (unsigned)l2c_calls, (unsigned)co_drops,
               (unsigned)BTM_GetNumAclLinks());
    l2c_max = 0;
  }
  out.printf("   role: %s, mode %s (changes %u)\r\n", role_name(link_role), mode_name(link_mode),
             (unsigned)role_changes);
  {
    esp_power_level_t lo = ESP_PWR_LVL_N0, hi = ESP_PWR_LVL_N0;
    esp_bredr_tx_power_get(&lo, &hi);
    static const int8_t DBM[] = {-12, -9, -6, -3, 0, 3, 6, 9};
    out.printf("   tx power: %d..%d dBm (set: %s)\r\n", DBM[lo & 7], DBM[hi & 7],
               ZxA2DP::tx_power_err == ESP_OK ? "ok" : esp_err_to_name(ZxA2DP::tx_power_err));
  }
  i2s_peak = 0;
}

// ---------------------------------------------------------------- commands

static uint32_t last_kick;   // millis() of the last discovery we started
static bool scan_pending;    // scan once the link is down

static void start_discovery() {
  if (a2dp.is_discovery_active()) return;
  esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 10, 0);   // 10 x 1.28 s
  last_kick = millis();
}

static void help(Print &out) {
  out.print(
      "OK commands:\r\n"
      "  status                  connection, target, audio (i2s peak since last status)\r\n"
      "  loader                  SD loader task: state, last link frame, code addresses on its stack\r\n"
      "  info                    one line: OK info <state> <scan> <MAC> <vol> <pin> <src> <name>\r\n"
      "  scan                    drop the link, search for speakers (EV found ... lines)\r\n"
      "  list                    devices found so far (index MAC rssi name)\r\n"
      "  connect <n|MAC|name>    pair/connect; remembered as target\r\n"
      "  disconnect              drop the link, stop auto-connect\r\n"
      "  forget                  clear target, stored last peer and its pairing\r\n"
      "  pin auto|<code>         PIN for legacy devices; auto tries 0000 1234 8888 1111\r\n"
      "  src i2s|tone            audio from the FPGA or the test tone\r\n"
      "  vol <0..127>            A2DP volume (also sent to the speaker)\r\n"
      "  mute on|off\r\n"
      "  bitpool <n>             SBC bitpool cap, 0 = none (default); next connection\r\n"
      "  rates                   sample rate history: i2s in / a2dp out per 2 s, rssi, bitpool, role, mode\r\n"
      "  tone <hz>               test tone, 0 = silence (20..20000)\r\n"
      "  wave sine|square        tone shape (square ~ ZX beeper)\r\n"
      "  level <0..100>          tone amplitude in %\r\n");
}

static void command(char *line, Print &out) {
  char *cmd = strtok(line, " \t");
  if (!cmd) return;
  char *arg = strtok(nullptr, "");
  if (arg) {
    while (*arg == ' ' || *arg == '\t') arg++;
    char *e = arg + strlen(arg);
    while (e > arg && (e[-1] == ' ' || e[-1] == '\t')) *--e = 0;
    if (!*arg) arg = nullptr;
  }

  if (!strcasecmp(cmd, "help") || !strcmp(cmd, "?")) {
    help(out);
  } else if (!strcasecmp(cmd, "status")) {
    status(out);
  } else if (!strcasecmp(cmd, "loader")) {
    loader_info(out);
  } else if (!strcasecmp(cmd, "rates")) {
    uint32_t n = rate_log_n < 24 ? rate_log_n : 24;
    out.printf("OK rates: %u entries (ms since start, i2s Hz, a2dp Hz, overflows, drift fixes, rssi delta, bitpool, role, mode)\r\n",
               (unsigned)rate_log_n);
    for (uint32_t i = rate_log_n - n; i < rate_log_n; i++) {
      const RateLog &r = rate_log[i % 24];
      out.printf("   %8u %6u %6u %8u %8u %4d %3u %s %s\r\n", (unsigned)r.ms, (unsigned)r.i2s_hz, (unsigned)r.a2dp_hz,
                 (unsigned)r.ovf, (unsigned)r.fix, (int)r.rssi, (unsigned)r.bitpool, role_name(r.role),
                 mode_name(r.mode));
    }
  } else if (!strcasecmp(cmd, "list")) {
    list_devs(out);
  } else if (!strcasecmp(cmd, "info")) {
    char m[18];
    mac_str(*a2dp.get_last_peer_address(), m);
    out.printf("OK info %s %s %s %u %s %s %u %u %u %u %u %u %s\r\n", conn_name(a2dp.get_connection_state()),
               a2dp.is_discovery_active() || scan_pending ? "scan" : "idle", m, volume,
               pin_fixed[0] ? pin_fixed : "auto", src_i2s ? "i2s" : "tone",
               (unsigned)i2s_underruns, (unsigned)i2s_overflows, (unsigned)(i2s_drops + i2s_dups),
               (unsigned)meas_i2s_hz, (unsigned)meas_a2dp_hz, (unsigned)rate_log_n,
               peer_name[0] ? peer_name : "-");
  } else if (!strcasecmp(cmd, "scan")) {
    portENTER_CRITICAL(&devs_mux);
    ndevs = 0;
    portEXIT_CRITICAL(&devs_mux);
    if (a2dp.get_connection_state() != ESP_A2D_CONNECTION_STATE_DISCONNECTED) {
      want_connect = false;                // looking for another device: drop this one first
      a2dp.disconnect();
      scan_pending = true;
    } else {
      start_discovery();
    }
    out.print("OK scanning\r\n");
  } else if (!strcasecmp(cmd, "connect")) {
    if (!arg) { out.print("ERR connect <n|MAC|name>\r\n"); return; }
    char *end;
    long n = strtol(arg, &end, 10);
    if (*end == 0 && n >= 0) {
      if (n >= ndevs) { out.print("ERR no such device, see list\r\n"); return; }
      mac_str(devs[n].mac, target);
      strlcpy(peer_name, devs[n].name, sizeof peer_name);
    } else {
      strlcpy(target, arg, sizeof target);
    }
    prefs.putString("target", target);
    want_connect = true;
    if (a2dp.get_connection_state() == ESP_A2D_CONNECTION_STATE_CONNECTED) a2dp.disconnect();
    else start_discovery();
    out.printf("OK connecting to %s\r\n", target);
  } else if (!strcasecmp(cmd, "disconnect")) {
    want_connect = false;
    a2dp.disconnect();
    out.print("OK\r\n");
  } else if (!strcasecmp(cmd, "forget")) {
    uint8_t tm[6];
    if (parse_mac(target, tm)) esp_bt_gap_remove_bond_device(tm);
    esp_bt_gap_remove_bond_device(*a2dp.get_last_peer_address());
    want_connect = false;
    target[0] = 0;
    peer_name[0] = 0;
    prefs.remove("target");
    a2dp.clean_last_connection();
    out.print("OK\r\n");
  } else if (!strcasecmp(cmd, "pin")) {
    if (arg && !strcasecmp(arg, "auto")) {
      pin_fixed[0] = 0;
      pin_try = 0;
    } else if (arg && strlen(arg) <= 16) {
      strlcpy(pin_fixed, arg, sizeof pin_fixed);
    } else {
      out.print("ERR pin auto|<1..16 chars>\r\n");
      return;
    }
    prefs.putString("pin", pin_fixed);
    out.print("OK\r\n");
  } else if (!strcasecmp(cmd, "src")) {
    if (arg && !strcasecmp(arg, "i2s")) src_i2s = true;
    else if (arg && !strcasecmp(arg, "tone")) src_i2s = false;
    else { out.print("ERR src i2s|tone\r\n"); return; }
    prefs.putBool("i2s", src_i2s);
    out.print("OK\r\n");
  } else if (!strcasecmp(cmd, "tone")) {
    long hz = arg ? atol(arg) : -1;
    if (hz < 0 || (hz > 0 && hz < 20) || hz > 20000) { out.print("ERR tone <0|20..20000>\r\n"); return; }
    set_tone(hz);
    prefs.putUInt("tone", hz);
    out.print("OK\r\n");
  } else if (!strcasecmp(cmd, "wave")) {
    if (arg && !strcasecmp(arg, "sine")) square_wave = false;
    else if (arg && !strcasecmp(arg, "square")) square_wave = true;
    else { out.print("ERR wave sine|square\r\n"); return; }
    prefs.putBool("square", square_wave);
    out.print("OK\r\n");
  } else if (!strcasecmp(cmd, "level")) {
    long p = arg ? atol(arg) : -1;
    if (p < 0 || p > 100) { out.print("ERR level <0..100>\r\n"); return; }
    set_level(p);
    prefs.putUInt("level", p);
    out.print("OK\r\n");
  } else if (!strcasecmp(cmd, "vol")) {
    long v = arg ? atol(arg) : -1;
    if (v < 0 || v > 127) { out.print("ERR vol <0..127>\r\n"); return; }
    volume = v;
    a2dp.set_volume(v);
    prefs.putUInt("vol", v);
    out.print("OK\r\n");
  } else if (!strcasecmp(cmd, "bitpool")) {
    long v = arg ? atol(arg) : -1;
    if (v < 0 || v > 250 || (v > 0 && v < 2)) { out.print("ERR bitpool <2..250> or 0 (no cap)\r\n"); return; }
    bitpool_cap = (uint8_t)v;
    prefs.putUChar("bitpool", (uint8_t)v);
    out.print("OK (used from the next connection)\r\n");
  } else if (!strcasecmp(cmd, "mute")) {
    if (arg && !strcasecmp(arg, "on")) muted = true;
    else if (arg && !strcasecmp(arg, "off")) muted = false;
    else { out.print("ERR mute on|off\r\n"); return; }
    out.print("OK\r\n");
  } else {
    out.printf("ERR unknown command '%s' (help)\r\n", cmd);
  }
}

// Line assembler per port; CR, LF or CRLF end a line, overlong lines are dropped.
struct LineIn {
  Stream &port;
  char buf[96];
  int len;
  bool overflow;

  void poll() {
    while (port.available()) {
      int c = port.read();
      if (c == '\r' || c == '\n') {
        buf[len] = 0;
        if (overflow) port.print("ERR line too long\r\n");
        else if (len) command(buf, port);
        len = 0;
        overflow = false;
      } else if (c >= 0x20 && c < 0x7f) {
        if (len < (int)sizeof buf - 1) buf[len++] = (char)c;
        else overflow = true;
      }
    }
  }
};

static LineIn usb_in{Serial, {0}, 0, false};
static LineIn uart_in{Serial2, {0}, 0, false};

// ---------------------------------------------------------------- setup / loop

void setup() {
  Serial.begin(115200);
  Serial2.begin(115200, SERIAL_8N1, UART2_RX, UART2_TX);
  gpio_pullup_en((gpio_num_t)UART2_RX);   // idle-high when the FPGA is not connected

  prefs.begin("btaudio", false);
  set_tone(prefs.getUInt("tone", 1000));
  set_level(prefs.getUInt("level", 30));
  square_wave = prefs.getBool("square", false);
  src_i2s = prefs.getBool("i2s", true);
  volume = prefs.getUInt("vol", 64);
  bitpool_cap = prefs.getUChar("bitpool", 0);
  strlcpy(target, prefs.getString("target", "").c_str(), sizeof target);
  strlcpy(pin_fixed, prefs.getString("pin", "").c_str(), sizeof pin_fixed);
  want_connect = target[0] != 0;

  i2s_start();

  a2dp.set_local_name("LSpectrum");
  a2dp.set_reset_ble(true);               // Classic BT only: the controller's BLE memory goes back to the heap
  a2dp.set_auto_reconnect(true);          // reconnect to the last peer stored in NVS
  a2dp.set_data_callback_in_frames(get_frames);
  a2dp.set_volume(volume);
  a2dp.start();

  Serial.print("\r\nLSpectrum BT audio. Type 'help'.\r\n");
  status(Serial);
  loader_begin();
}

void loop() {
  loader_poll();
  loader_check();
  usb_in.poll();
  uart_in.poll();

  // Report newly found (or newly named) devices.
  for (int i = 0; i < ndevs; i++) {
    if (devs[i].reported) continue;
    Dev d;
    portENTER_CRITICAL(&devs_mux);
    devs[i].reported = true;
    d = devs[i];
    portEXIT_CRITICAL(&devs_mux);
    char m[18];
    mac_str(d.mac, m);
    event("found %d %s %d %s", i, m, d.rssi, d.name[0] ? d.name : "(no name)");
  }

  // Report connection / discovery changes.
  static esp_a2d_connection_state_t last_conn = ESP_A2D_CONNECTION_STATE_DISCONNECTED;
  static bool last_disc = false;
  esp_a2d_connection_state_t conn = a2dp.get_connection_state();
  static uint32_t conn_ms, vol_ms;
  if (conn != last_conn) {
    last_conn = conn;
    conn_ms = millis();
    char m[18];
    mac_str(*a2dp.get_last_peer_address(), m);
    event("%s %s %s", conn_name(conn), m, peer_name);
  }

  // Volume: when a speaker connects it reports its own volume over AVRCP and the library
  // takes it (BluetoothA2DPSource bt_av_notify_evt_handler), so the stream played at the
  // speaker's last volume while 'vol' (F3 menu) still showed the stored one. For the first
  // 5 s of a connection the stored volume is put back (at most every 0.5 s, the speaker
  // answers each one); after that, changes from the speaker's own buttons are taken over,
  // so the menu shows the volume in use.
  // A speaker that reports no volume keeps its own one (often low): set_volume() before the
  // connection sends nothing, and the check below sees no difference. So the stored volume is
  // sent to the speaker once, 1.5 s after it connects (seen on hardware: low until Right in F3).
  static bool vol_sent;
  if (conn != ESP_A2D_CONNECTION_STATE_CONNECTED) vol_sent = false;
  else if (!vol_sent && millis() - conn_ms >= 1500) {
    vol_sent = true;
    esp_avrc_ct_send_set_absolute_volume_cmd(0, volume);
    event("volume %u sent to the speaker", (unsigned)volume);
  }
  if (conn == ESP_A2D_CONNECTION_STATE_CONNECTED) {
    int v = a2dp.get_volume();
    if (millis() - conn_ms < 5000) {
      if (v != (int)volume && millis() - vol_ms >= 500) {
        vol_ms = millis();
        a2dp.set_volume(volume);
        event("volume %u restored (speaker reported %d)", (unsigned)volume, v);
      }
    } else if (v != (int)volume) {
      volume = v;
      event("volume %u (set on the speaker)", (unsigned)volume);
    }
  }

  // Audio stream events, and a stream that stopped while the link stays (see kick_media)
  static int last_audio = -1;
  if (audio_state != last_audio) {
    last_audio = audio_state;
    event("audio %s", last_audio == ESP_A2D_AUDIO_STATE_STARTED ? "started" : "suspended");
  }
  static uint32_t kick_ms;
  if (conn == ESP_A2D_CONNECTION_STATE_CONNECTED && millis() - conn_ms > 3000 && millis() - kick_ms > 3000 &&
      esp_timer_get_time() - cb_last > 3000000) {
    kick_ms = millis();
    if (a2dp.kick_media()) event("audio stream stopped: starting it again (%u)", (unsigned)media_restarts);
  }
  // A stream the kick cannot start again (seen 2026-11-05 after quick disconnects / reconnects from
  // the headphones: connected, media state stays idle, no audio asked for minutes): drop the link and
  // connect again, as the user would from F3. Only with a target (not after a deliberate disconnect).
  static uint32_t silent_ms;
  bool silent = conn == ESP_A2D_CONNECTION_STATE_CONNECTED && millis() - conn_ms > 3000 &&
                esp_timer_get_time() - cb_last > 3000000;
  if (!silent) silent_ms = 0;
  else if (!silent_ms) silent_ms = millis();
  else if (millis() - silent_ms > 15000 && want_connect) {
    silent_ms = 0;
    relinks++;
    event("audio stream did not start again: reconnecting (%u)", (unsigned)relinks);
    a2dp.disconnect();
    scan_pending = true;                   // search for the target as soon as the link is down
  }

  // Rate check (see i2s_gross): both rates every 2 s, kept in the history
  static int64_t rate_t;
  static uint32_t rate_g0, rate_q0, rate_first, kept_i2s, kept_a2dp;
  int64_t now_us = esp_timer_get_time();
  if (now_us - rate_t >= 2000000) {
    uint32_t g = i2s_gross, q = a2dp_req;
    static uint32_t pk_n0, pk_f0;
    if (rate_t) {
      uint32_t pn = pk_n, pf = pk_frames;
      meas_pk_hz = (uint32_t)((pn - pk_n0) * 1e6 / (now_us - rate_t) + 0.5);
      meas_pkfr_hz = (uint32_t)((pf - pk_f0) * 1e6 / (now_us - rate_t) + 0.5);
      pk_n0 = pn;
      pk_f0 = pf;
    }
    static uint32_t rssi_n;
    if (conn == ESP_A2D_CONNECTION_STATE_CONNECTED && rssi_n++ % 5 == 0)   // every 10 s
      esp_bt_gap_read_rssi_delta(*a2dp.get_last_peer_address());
    // Link role and power mode (see BTM_GetRole above)
    uint8_t lr = 0xff, lm = 0xff;
    if (conn == ESP_A2D_CONNECTION_STATE_CONNECTED) {
      BTM_GetRole(*a2dp.get_last_peer_address(), &lr);
      BTM_ReadPowerMode(*a2dp.get_last_peer_address(), &lm);
    }
    if (lr != link_role || lm != link_mode) {
      if (lr != 0xff && link_role != 0xff && lr != link_role) role_changes++;
      link_role = lr;
      link_mode = lm;
      if (lr != 0xff) event("link role %s, mode %s", role_name(lr), mode_name(lm));
    }
    if (rate_t) {
      double sec = (now_us - rate_t) / 1e6;
      meas_i2s_hz = (uint32_t)((g - rate_g0) / sec + 0.5);
      meas_a2dp_hz = (uint32_t)((q - rate_q0) / sec + 0.5);
      auto off = [](uint32_t a, uint32_t b) { return a * 50 > b * 51 || a * 50 < b * 49; };   // > 2 %
      bool streaming = conn == ESP_A2D_CONNECTION_STATE_CONNECTED && now_us - cb_last < 200000 && meas_a2dp_hz > 0;
      if (!streaming) rate_first = 0;
      else if (rate_first < 5 || off(meas_i2s_hz, kept_i2s) || off(meas_a2dp_hz, kept_a2dp)) {
        if (rate_first >= 5)
          event("audio rates changed: i2s %u Hz, a2dp %u Hz", (unsigned)meas_i2s_hz, (unsigned)meas_a2dp_hz);
        rate_first++;
        kept_i2s = meas_i2s_hz;
        kept_a2dp = meas_a2dp_hz;
        rate_log[rate_log_n % 24] = {millis(), meas_i2s_hz, meas_a2dp_hz, i2s_overflows, i2s_drops + i2s_dups,
                                     link_rssi, bp_max, link_role, link_mode};
        rate_log_n++;
      }
    }
    rate_t = now_us;
    rate_g0 = g;
    rate_q0 = q;
  }
  static uint32_t last_cfg;
  if (cfg_events != last_cfg) {
    last_cfg = cfg_events;
    event("audio codec: SBC %u Hz (0x%02x)", (unsigned)sbc_hz(sbc_cfg), (unsigned)sbc_cfg);
  }

  static uint32_t last_forced = 0;
  if (codec_forced != last_forced) {
    last_forced = codec_forced;
    event("codec set up by the IDF fix (%u)", (unsigned)last_forced);
  }
  bool disc = a2dp.is_discovery_active();
  if (disc != last_disc) {
    last_disc = disc;
    event("discovery %s", disc ? "on" : "off");
  }

  if (scan_pending && conn == ESP_A2D_CONNECTION_STATE_DISCONNECTED) {
    scan_pending = false;
    start_discovery();
  }

  // The library stops searching after a deliberate disconnect and gives up after
  // its reconnect retries; restart discovery if we still have a target to reach.
  // The first 15 s belong to the library's own start-up (10 s wait + reconnect).
  if (want_connect && conn == ESP_A2D_CONNECTION_STATE_DISCONNECTED && !disc &&
      millis() > 15000 && millis() - last_kick > 15000)
    start_discovery();

  delay(10);
}
