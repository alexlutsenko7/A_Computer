/* v1.ino - the LSpectrum system controller on the ESP32: SD tape loader + Bluetooth audio. */
/* Board : ESP32-WROOM-32 dev board (CP2102, Type-C). Arduino core esp32 3.3.x, */
/*         board "ESP32 Dev Module". Needs Classic BT (original ESP32 only). */
/* Lib   : ESP32-A2DP by Phil Schatzmann, v1.8.11; AAudioLinkFix (libraries/, copy it into the */
/*         sketchbook's libraries folder). */
/* SD tape loader (src/): owns the SD card (VSPI) and runs the browser, TAP/TZX playback, */
/* recording, .z80 load/save and the F3 menu as a task, driving the FPGA's loader hardware over */
/* the SPI link (src/esp_hw.cpp, rtl/esp_link.v). It starts when the FPGA answers with the */
/* LSpectrum core ID. */
/* Bluetooth audio: an A2DP source (like a phone) that sends 44.1 kHz stereo to a BT */
/* speaker/headphones. Audio comes from the FPGA over I2S (the ESP32 is the I2S */
/* master: BCLK GPIO26, LRCK GPIO25 out, DATA GPIO22 in; rtl/bt_i2s.v), */
/* or from a built-in test tone ("src tone"). */
/* Pairing: SSP devices (BT 2.1+, almost all) are accepted without a code. Legacy */
/* devices ask for a PIN: by default the common codes 0000, 1234, 8888, 1111 are */
/* tried in turn (one per connection attempt), or a fixed one is set with "pin". */
/* Control: line commands at 115200 baud on UART2 (RX GPIO16, TX GPIO17), which the */
/* FPGA's UART connects to the loader's F3 menu (src/bt.cpp), and on USB (Serial) for */
/* debugging; both take the same commands. */
/* Replies go to the port the command came from and start with "OK" or "ERR"; */
/* unsolicited events go to both ports and start with "EV". "help" lists them. */
/* Input lines may end in CR, LF or CR+LF; every output line ends in CR+LF. */

/* links with -Wl,--wrap=bta_av_co_audio_set_codec */
#include <AAudioLinkFix.h>
#include <BluetoothA2DPSource.h>
#include <Preferences.h>
/* pins and I2S */
#include <driver/gpio.h>
#include <driver/i2s_std.h>
/* the sine of the test tone; the loader */
#include <math.h>
#include "src/loader.h"

/* the audio's sample rate */
#define SAMPLE_RATE 44100
/* the control UART's pins and speed */
#define UART2_RX 16
#define UART2_TX 17
#define UART_BAUD 115200
/* the I2S pins */
#define I2S_BCLK 26
#define I2S_LRCK 25
#define I2S_DIN 22
/* devices kept from a search */
#define MAX_DEVS 16
/* PINs tried in turn for legacy devices */
#define N_AUTO_PINS 4
/* text buffers */
#define EVENT_BUF 128
/* a device name and its end */
#define BDNAME_BUF (ESP_BT_GAP_MAX_BDNAME_LEN + 1)
#define MAC_BUF 18
#define MAC_TEXT_LEN 17
/* a MAC's bytes */
#define MAC_LEN 6
#define MAC_BYTE_1 1
#define MAC_BYTE_2 2
/* the last three */
#define MAC_BYTE_3 3
#define MAC_BYTE_4 4
#define MAC_BYTE_5 5
/* text buffers: a name, the target, a PIN */
#define NAME_BUF 32
#define TARGET_BUF 40
#define PIN_BUF 17
/* a PIN's length, a command line */
#define PIN_LEN 16
#define LINE_BUF 96
/* the answers of the wrapped stack functions */
#define STACK_TRUE 1
#define STACK_FALSE 0
/* the SBC codec information element (tA2D_SBC_CIE): its bytes, the places of the bitpool range, */
/* and what a sane range is */
#define CIE_LEN 8
#define CIE_MAX_BITPOOL 5
#define CIE_MIN_BITPOOL 6
/* a sane range */
#define BITPOOL_MIN 2
#define BITPOOL_MAX 250
/* link role and power mode: no link */
#define LINK_NONE 0xff
#define ROLE_MASTER 0
#define ROLE_SLAVE 1
/* power modes */
#define MODE_ACTIVE 0
#define MODE_HOLD 1
/* sniff, park */
#define MODE_SNIFF 2
#define MODE_PARK 3
/* the SBC frame count in a media packet's header */
#define PKT_FRAMES_MASK 0x0f
/* L2CA_FlushChannel with this count is a query */
#define L2CAP_FLUSH_QUERY 0
/* the I2S DMA: 12 buffers of 256 frames = 12 x 5.8 ms */
#define DMA_BUFS 12
#define DMA_LEN 256
/* the backlog at the start of a tick is kept in this range, in frames */
#define BACKLOG_LO 1792
#define BACKLOG_MID 2048
#define BACKLOG_HI 2304
/* further outside than this, the backlog is put back in one jump; back inside, filling ends */
#define BACKLOG_FAR 512
#define BACKLOG_NEAR 256
/* a burst too short to drop or repeat a frame in */
#define ADJ_MIN_FRAMES 2
/* frames thrown away per read */
#define JUNK_FRAMES 64
/* reading the I2S data: tries, and the wait per try in RTOS ticks */
#define READ_TRIES 4
#define READ_WAIT_TICKS 2
/* the callback's steps: a step later than this is late (us); longer than this, the stream had stopped; */
/* the calls of one tick follow each other within this time */
#define LATE_US 60000
#define STREAM_GAP_US 2000000
#define TICK_GAP_US 12000
/* units */
#define US_PER_MS 1000
#define US_PER_S 1e6
/* the rate history */
#define RATE_LOG_LEN 24
#define RATE_FIRST_KEPT 5
/* a rate differs when it is more than 2 % off: a * 50 against b * 51 and b * 49 */
#define RATE_SCALE 50
#define RATE_SCALE_HIGH 51
#define RATE_SCALE_LOW 49
/* rounding to the nearest */
#define ROUND_HALF 0.5
/* SBC sampling frequency bits of the codec byte, and the rates they mean */
#define SBC_16K 0x80
#define SBC_32K 0x40
#define SBC_44K 0x20
/* 48 kHz; then the rates in Hz */
#define SBC_48K 0x10
#define HZ_16K 16000
#define HZ_32K 32000
/* 44.1 and 48 kHz */
#define HZ_44K 44100
#define HZ_48K 48000
/* the test tone: a sine table of 1024 entries, addressed by the top 10 bits of a 32-bit phase */
#define SINE_LEN 1024
#define SINE_PHASE_SHIFT 22
#define SINE_PEAK 32767.0
/* a full turn, the phase's width and its half */
#define SINE_TURN 6.28318530717958647692
#define PHASE_BITS 32
#define PHASE_HALF 0x80000000u
/* amplitude, percent */
#define AMP_MAX 32767
#define AMP_SHIFT 15
#define PERCENT 100
/* a device's signal strength is not known */
#define RSSI_UNKNOWN (-129)
/* A2DP media states of the library (APP_AV_MEDIA_STATE_*) */
#define MEDIA_IDLE 0
#define MEDIA_STARTED 2
/* audio state: none yet */
#define AUDIO_NONE (-1)
/* the search: 10 x 1.28 s */
#define INQUIRY_LEN 10
/* command limits */
#define TONE_MIN 20
#define TONE_MAX 20000
#define LEVEL_MAX 100
/* volume, no number given, the number base */
#define VOL_MAX 127
#define NO_NUMBER (-1)
#define DECIMAL 10
/* printable characters of a command line */
#define CHAR_FIRST 0x20
#define CHAR_END 0x7f
/* stored settings: their defaults */
#define DEFAULT_TONE 1000
#define DEFAULT_LEVEL 30
#define DEFAULT_VOL 64
/* times of the main loop, in ms */
#define VOL_SEND_MS 1500
#define VOL_RESTORE_MS 5000
#define VOL_RESTORE_STEP_MS 500
/* a stream that stopped */
#define STREAM_SETTLE_MS 3000
#define KICK_MS 3000
#define RELINK_MS 15000
/* start-up, discovery, the loop's pause */
#define STARTUP_MS 15000
#define DISCOVERY_RETRY_MS 15000
#define LOOP_DELAY_MS 10
/* times of the main loop, in us */
#define SILENT_US 3000000
#define RATE_PERIOD_US 2000000
#define STREAMING_US 200000
/* the RSSI is read every 5th rate period (10 s) */
#define RSSI_EVERY 5
/* transmit power levels as dBm */
#define DBM_LEVELS 8
#define DBM_LEVEL_MASK 7
/* flags as numbers */
#define YES 1

/* the header of a Bluedroid buffer (BT_HDR) */
struct BtHdr
{
/* the fields, as the stack has them */
    uint16_t ui16_event;
    uint16_t ui16_len;
/* offset of the data, frames in the packet */
    uint16_t ui16_offset;
    uint16_t ui16_layer_specific;
};

/* one entry of the rate history */
struct RateLog
{
/* when, and the two rates */
    uint32_t ui32_ms;
    uint32_t ui32_i2s_hz;
    uint32_t ui32_a2dp_hz;
/* DMA overflows and drift fixes so far */
    uint32_t ui32_ovf;
    uint32_t ui32_fix;
    int8_t i8_rssi;
/* the link then */
    uint8_t ui8_bitpool;
    uint8_t ui8_role;
    uint8_t ui8_mode;
};

/* the sine table, built by the compiler: in flash, not in RAM */
struct SineTab
{
/* the table */
    int16_t ai16_v[SINE_LEN];
    constexpr SineTab() : ai16_v{}
    {
/* one period, built at compile time */
        for (int32_t i32_index = 0; i32_index < SINE_LEN; i32_index++)
        {
            ai16_v[i32_index] = (int16_t)__builtin_lround(SINE_PEAK * __builtin_sin((i32_index * SINE_TURN) / SINE_LEN));
        }
    }
};

/* a device seen by a search */
struct Dev
{
/* address, name, signal strength */
    uint8_t aui8_mac[MAC_LEN];
    char ac_name[NAME_BUF];
    int32_t i32_rssi;
/* told to the user already */
    bool b_reported;
};

/* stack functions wrapped or called here */
extern "C" uint8_t __real_bta_av_co_audio_set_codec(const void *p_feeding, void *p_status);
extern "C" uint8_t btc_av_is_connected(void);
extern "C" uint8_t __real_bta_av_co_get_remote_bitpool_pref(uint8_t *pui8_min, uint8_t *pui8_max);
/* tA2D_SBC_CIE (stack/a2d_sbc.h): samp_freq, ch_mode, block_len, num_subbands, alloc_mthd, */
/* max_bitpool, min_bitpool, all UINT8 */
extern "C" uint8_t bta_av_co_audio_get_sbc_config(uint8_t *pui8_cie, uint16_t *pui16_minmtu);
/* 0 = BTM_SUCCESS; mode: 0 active, 2 sniff */
extern "C" int BTM_GetRole(uint8_t *pui8_bda, uint8_t *pui8_role);
extern "C" int BTM_ReadPowerMode(uint8_t *pui8_bda, uint8_t *pui8_mode);
extern "C" uint16_t __real_AVDT_WriteReqOpt(uint8_t ui8_handle, void *p_pkt, uint32_t ui32_ts, uint8_t ui8_m_pt,
                                            uint8_t ui8_opt);
/* ACL links, the L2CAP flush, the dropped-packet hook */
extern "C" uint16_t BTM_GetNumAclLinks(void);
extern "C" uint16_t __real_L2CA_FlushChannel(uint16_t ui16_lcid, uint16_t ui16_num);
extern "C" void __real_bta_av_co_audio_drop(uint8_t ui8_handle);

/* PINs tried in turn for legacy devices */
static const char *const g_apc_auto_pins[N_AUTO_PINS] = { "0000", "1234", "8888", "1111" };
/* transmit power levels in dBm */
static const int8_t g_ai8_dbm[DBM_LEVELS] = { -12, -9, -6, -3, 0, 3, 6, 9 };
/* the rate history (ring) */
static RateLog g_as_rate_log[RATE_LOG_LEN];
/* the devices found */
static Dev g_as_devs[MAX_DEVS];
/* the sine table and a pointer to its values */
static constexpr SineTab g_s_sine_tab;
static const int16_t *const g_pi16_sine = g_s_sine_tab.ai16_v;
/* MAC "aa:bb:cc:dd:ee:ff" or exact device name to connect to; the connected device's name */
static char g_ac_target[TARGET_BUF];
static char g_ac_peer_name[NAME_BUF];
/* the fixed PIN; "" = auto (the list above) */
static char g_ac_pin_fixed[PIN_BUF];
/* the stored settings */
Preferences g_s_prefs;
/* times the codec fix was needed */
static volatile uint32_t g_ui32_codec_forced;
/* the SBC bitpool cap (0 = none); the range from the codec configuration, and the maximum used */
static volatile uint8_t g_ui8_bitpool_cap = 0;
static volatile uint8_t g_ui8_bp_peer_min;
static volatile uint8_t g_ui8_bp_peer_max;
/* the maximum used, calls counted */
static volatile uint8_t g_ui8_bp_max;
static volatile uint32_t g_ui32_bp_calls;
/* the last range came from the sink's SET CONFIG */
static volatile bool g_b_bp_from_peer;
/* link role (0 master, 1 slave) and power mode; LINK_NONE = no link */
static uint8_t g_ui8_link_role = LINK_NONE;
static uint8_t g_ui8_link_mode = LINK_NONE;
static uint32_t g_ui32_role_changes;
/* media packets: count, SBC frames, write errors, the largest seen */
static volatile uint32_t g_ui32_pk_n;
static volatile uint32_t g_ui32_pk_frames;
static volatile uint32_t g_ui32_pk_err;
/* the largest packet in bytes and in frames */
static volatile uint16_t g_ui16_pk_max_len;
static volatile uint16_t g_ui16_pk_max_frames;
/* packets and frames per second, measured by loop() */
static uint32_t g_ui32_meas_pk_hz;
static uint32_t g_ui32_meas_pkfr_hz;
/* buffers L2CAP holds for the media channel: last, maximum, queries; packets BTA dropped */
static volatile uint16_t g_ui16_l2c_last;
static volatile uint16_t g_ui16_l2c_max;
/* queries; packets BTA dropped */
static volatile uint32_t g_ui32_l2c_calls;
static volatile uint32_t g_ui32_co_drops;
/* audio source: I2S (false = test tone); muted */
static volatile bool g_b_src_i2s;
static volatile bool g_b_muted;
/* the I2S receive channel */
static i2s_chan_handle_t g_s_i2s_rx;
static volatile uint32_t g_ui32_i2s_underruns;
/* frames the DMA delivered (ISR), frames read by get_frames, DMA buffers overwritten (ISR) */
static volatile uint32_t g_ui32_i2s_rx_frames;
static uint32_t g_ui32_i2s_rd_frames;
static volatile uint32_t g_ui32_i2s_overflows;
/* drift corrections, and jumps back to BACKLOG_MID */
static uint32_t g_ui32_i2s_drops;
static uint32_t g_ui32_i2s_dups;
static uint32_t g_ui32_i2s_resyncs;
/* silence until the backlog is back at BACKLOG_MID */
static bool g_b_filling;
/* callback steps more than LATE_US after the one before; the longest step distance; the last step */
static volatile uint32_t g_ui32_cb_late;
static volatile uint32_t g_ui32_cb_max_us;
static int64_t g_i64_cb_last;
/* largest |sample| since the last status */
static volatile int32_t g_i32_i2s_peak;
/* frames the DMA delivered, overwritten ones included (ISR); frames get_frames was asked for */
static volatile uint32_t g_ui32_i2s_gross;
static volatile uint32_t g_ui32_a2dp_req;
/* the last rate measurement (loop) */
static uint32_t g_ui32_meas_i2s_hz;
static uint32_t g_ui32_meas_a2dp_hz;
/* first SBC byte of the last ESP_A2D_AUDIO_CFG_EVT (0 = none), and how many came */
static volatile uint8_t g_ui8_sbc_cfg;
static volatile uint32_t g_ui32_cfg_events;
/* ESP_BT_GAP_READ_RSSI_DELTA_EVT: 0 = in the golden range, below 0 weaker */
static volatile int8_t g_i8_link_rssi;
static volatile uint32_t g_ui32_rssi_reads;
/* entries written to the rate history */
static uint32_t g_ui32_rate_log_n;
/* the test tone: phase step per sample (2^32 = one period), amplitude 0..32767, shape, phase */
static volatile uint32_t g_ui32_phase_inc;
static volatile int32_t g_i32_amp;
/* square instead of sine; the phase */
static volatile bool g_b_square_wave;
static uint32_t g_ui32_phase;
/* the tone's frequency and level as set, and the volume */
static uint32_t g_ui32_tone_hz;
static uint32_t g_ui32_level_pct;
static uint32_t g_ui32_volume;
/* devices found, and the lock for the list (the BT task writes it) */
static int32_t g_i32_ndevs;
static portMUX_TYPE g_s_devs_mux = portMUX_INITIALIZER_UNLOCKED;
/* connect to the target when discovery sees it */
static volatile bool g_b_want_connect;
/* index into the PIN list; an A2DP link is up */
static volatile int32_t g_i32_pin_try;
static volatile bool g_b_link_up;
/* audio stream state, written in the BT task, reported by loop(): last ESP_A2D_AUDIO_STATE_EVT */
/* state, events counted, streams started again by us, links made again because no stream came back */
static volatile int32_t g_i32_audio_state = AUDIO_NONE;
static volatile uint32_t g_ui32_audio_events;
/* streams restarted, links made again */
static volatile uint32_t g_ui32_media_restarts;
static uint32_t g_ui32_relinks;
/* millis() of the last discovery we started; scan once the link is down */
static uint32_t g_ui32_last_kick;
static bool g_b_scan_pending;
/* loop(): what was reported last */
static esp_a2d_connection_state_t g_e_last_conn = ESP_A2D_CONNECTION_STATE_DISCONNECTED;
static bool g_b_last_disc = false;
static int32_t g_i32_last_audio = AUDIO_NONE;
/* codec events */
static uint32_t g_ui32_last_cfg;
static uint32_t g_ui32_last_forced = 0;
/* loop(): when the link came up, when the volume was restored last, the volume was sent */
static uint32_t g_ui32_conn_ms;
static uint32_t g_ui32_vol_ms;
static bool g_b_vol_sent;
/* loop(): when the stream was kicked last, and since when it is silent */
static uint32_t g_ui32_kick_ms;
static uint32_t g_ui32_silent_ms;
/* loop(): the rate check's last time and counts, measurements kept, RSSI read counter */
static int64_t g_i64_rate_t;
static uint32_t g_ui32_rate_g0;
static uint32_t g_ui32_rate_q0;
/* measurements kept */
static uint32_t g_ui32_rate_first;
static uint32_t g_ui32_kept_i2s;
static uint32_t g_ui32_kept_a2dp;
/* packet counts, RSSI reads */
static uint32_t g_ui32_pk_n0;
static uint32_t g_ui32_pk_f0;
static uint32_t g_ui32_rssi_n;

/* ESP-IDF 5.5 fix */
/* When the speaker opens the A2DP stream itself (Bose headphones reconnect to */
/* their last source by themselves, or answer our connect with their own) and */
/* configures it with the standard SBC setup, Bluedroid never asks for the sink's */
/* capabilities. bta_av_co_audio_set_codec() then fails ("peer supports no codec"), */
/* btc_a2dp_source_setup_codec() skips the encoder setup, and the first stream */
/* start divides by the encoder's 0 blocks in SBC_Encoder_Init. That */
/* configuration is Bluedroid's own default (44.1 kHz, joint stereo, 16 blocks, */
/* 8 subbands), so report success while a link is open: the encoder and the PCM */
/* feeding are then set up with it (bitpool range from the peer's set-config). */
/* The caller ignores *status. */
extern "C" uint8_t __wrap_bta_av_co_audio_set_codec(const void *p_feeding, void *p_status)
{
/* local variables */
    uint8_t ui8_result;

    ui8_result = STACK_TRUE;
    if (__real_bta_av_co_audio_set_codec(p_feeding, p_status) == 0)
    {
/* failed: success is reported only while a link is open */
        if (btc_av_is_connected() == 0)
        {
            ui8_result = STACK_FALSE;
        }
        else
        {
/* forced by us: counted */
            g_ui32_codec_forced = g_ui32_codec_forced + YES;
        }
    }
    return ui8_result;
}

/* SBC bitpool cap (`bitpool <n>`, 0 = none = default). btc_a2dp_source_encoder_update() takes the */
/* sink's bitpool range from bta_av_co_get_remote_bitpool_pref() when that returns TRUE (the sink */
/* sent SET CONFIG), otherwise the current SBC configuration's range. With a cap set, the wrapper */
/* always returns TRUE with the range capped (the configuration's range when the sink gave none), so */
/* the encoder sends a lower bitrate: bitpool 53 (Bluedroid's default) = 328 kbit/s, 35 = 229 kbit/s, */
/* 29 = 196 kbit/s at 44.1 kHz joint stereo. Stored; used from the next stream start (reconnect). */
/* History: 29 was the default from 2026-11-05 to 2026-11-10, when some connections carried only 2/3 */
/* of the audio. The cause was not the radio but the internal heap (see "Media packets" below): with */
/* a smaller bitpool one packet per tick was enough. */
extern "C" uint8_t __wrap_bta_av_co_get_remote_bitpool_pref(uint8_t *pui8_min, uint8_t *pui8_max)
{
/* local variables */
    uint8_t aui8_cie[CIE_LEN] = { 0 };
    uint16_t ui16_mtu;
    uint8_t ui8_cap;
/* the result, a sane range */
    uint8_t ui8_result;
    bool b_range;

/* start values */
    ui16_mtu = 0;
    ui8_cap = 0;
    ui8_result = __real_bta_av_co_get_remote_bitpool_pref(pui8_min, pui8_max);
/* the stack's own answer is kept for the status */
    b_range = true;
    g_b_bp_from_peer = ui8_result;
/* the sink gave no range: take the one of the SBC configuration, if it is a sane one */
    if (ui8_result == 0)
    {
        bta_av_co_audio_get_sbc_config(aui8_cie, &ui16_mtu);
        if ((aui8_cie[CIE_MIN_BITPOOL] < BITPOOL_MIN) || (aui8_cie[CIE_MAX_BITPOOL] > BITPOOL_MAX) ||
            (aui8_cie[CIE_MIN_BITPOOL] > aui8_cie[CIE_MAX_BITPOOL]))
        {
/* not a sane range: leave it alone */
            b_range = false;
        }
        else
        {
/* the range from the codec configuration */
            *pui8_max = aui8_cie[CIE_MAX_BITPOOL];
            *pui8_min = aui8_cie[CIE_MIN_BITPOOL];
        }
    }
    if (b_range)
    {
/* kept for the status */
        g_ui8_bp_peer_min = *pui8_min;
        g_ui8_bp_peer_max = *pui8_max;
/* the cap, and a minimum that is not above the maximum */
        ui8_cap = g_ui8_bitpool_cap;
        if ((ui8_cap != 0) && (*pui8_max > ui8_cap))
        {
            *pui8_max = ui8_cap;
        }
/* the minimum */
        if (*pui8_min > *pui8_max)
        {
            *pui8_min = *pui8_max;
        }
/* the maximum in use, counted */
        g_ui8_bp_max = *pui8_max;
        g_ui32_bp_calls = g_ui32_bp_calls + YES;
/* with a cap the range is always used */
        if (g_ui8_bitpool_cap != 0)
        {
            ui8_result = STACK_TRUE;
        }
    }
    return ui8_result;
}

/* Link role and power mode of the open link, shown by `status` / `rates` (diagnosis; Bluedroid */
/* accepts an incoming connection as slave and never asks for a switch, the audio does not depend on it). */
static const char *role_name(uint8_t ui8_role)
{
/* local variables */
    const char *pc_name;

/* start values */
    pc_name = "-";
    if (ui8_role == ROLE_MASTER)
    {
        pc_name = "master";
    }
/* slave */
    else if (ui8_role == ROLE_SLAVE)
    {
        pc_name = "slave";
    }
    else
    {
/* no link */
    }
    return pc_name;
}

/* the name of a power mode */
static const char *mode_name(uint8_t ui8_mode)
{
/* local variables */
    const char *pc_name;

/* start values */
    pc_name = "-";
    if (ui8_mode == MODE_ACTIVE)
    {
        pc_name = "active";
    }
/* hold */
    else if (ui8_mode == MODE_HOLD)
    {
        pc_name = "hold";
    }
/* sniff */
    else if (ui8_mode == MODE_SNIFF)
    {
        pc_name = "sniff";
    }
/* park */
    else if (ui8_mode == MODE_PARK)
    {
        pc_name = "park";
    }
    else
    {
/* no link */
    }
    return pc_name;
}

/* Media packets. Bluedroid builds every A2DP media packet in a 4112-byte buffer from the internal */
/* heap (osi_malloc(BTC_MEDIA_AA_BUF_SIZE) in btc_media_aa_prep_sbc_2_send) and fills it up to the */
/* sink's MTU: 7 SBC frames at bitpool 53 with an MTU of 883, so a 30 ms tick (10.3 frames) needs two */
/* packets. When the second allocation fails the function returns without a word: those frames are */
/* never read, the sink gets 2/3 of the audio (29,867 Hz pulled; choppy, "sped up"), and with less */
/* memory still nothing at all (connected, silent). Found 2026-11-10; the heap then had 13-18 KB free */
/* while streaming. Keep the internal heap well above 20 KB while streaming (`status`, heap line). */
/* Counted where BTA hands a packet to AVDTP: packets, SBC frames (layer_specific) and bytes. */
extern "C" uint16_t __wrap_AVDT_WriteReqOpt(uint8_t ui8_handle, void *p_pkt, uint32_t ui32_ts, uint8_t ui8_m_pt,
                                            uint8_t ui8_opt)
{
/* local variables */
    const BtHdr *ps_hdr;
    uint16_t ui16_len;
/* SBC frames in it, the result */
    uint16_t ui16_frames;
    uint16_t ui16_result;

/* read before the stack takes the buffer */
    ps_hdr = (const BtHdr *)p_pkt;
    ui16_len = ps_hdr->ui16_len;
    ui16_frames = ps_hdr->ui16_layer_specific & PKT_FRAMES_MASK;
/* the packet goes on; counted */
    ui16_result = __real_AVDT_WriteReqOpt(ui8_handle, p_pkt, ui32_ts, ui8_m_pt, ui8_opt);
    g_ui32_pk_n = g_ui32_pk_n + YES;
    g_ui32_pk_frames = g_ui32_pk_frames + ui16_frames;
/* the largest packet seen */
    if (ui16_len > g_ui16_pk_max_len)
    {
        g_ui16_pk_max_len = ui16_len;
    }
/* the most frames seen */
    if (ui16_frames > g_ui16_pk_max_frames)
    {
        g_ui16_pk_max_frames = ui16_frames;
    }
/* a write the stack refused */
    if (ui16_result != 0)
    {
        g_ui32_pk_err = g_ui32_pk_err + YES;
    }
    return ui16_result;
}

/* More of the same: how many buffers L2CAP still holds for the media channel when BTA asks (it sends */
/* a new packet only below a limit), packets BTA dropped, and the number of ACL links the stack counts. */
extern "C" uint16_t __wrap_L2CA_FlushChannel(uint16_t ui16_lcid, uint16_t ui16_num)
{
    uint16_t ui16_result;

    ui16_result = __real_L2CA_FlushChannel(ui16_lcid, ui16_num);
/* L2CAP_FLUSH_CHANS_GET: a query */
    if (ui16_num == L2CAP_FLUSH_QUERY)
    {
        g_ui16_l2c_last = ui16_result;
/* the most held */
        if (ui16_result > g_ui16_l2c_max)
        {
            g_ui16_l2c_max = ui16_result;
        }
/* queries counted */
        g_ui32_l2c_calls = g_ui32_l2c_calls + YES;
    }
    return ui16_result;
}

/* a packet BTA dropped */
extern "C" void __wrap_bta_av_co_audio_drop(uint8_t ui8_handle)
{
    g_ui32_co_drops = g_ui32_co_drops + YES;
    __real_bta_av_co_audio_drop(ui8_handle);
}

/* output */

/* an unsolicited event line to both ports */
static void event(const char *pc_fmt, ...)
{
/* local variables */
    char ac_buf[EVENT_BUF];
    va_list s_args;

/* the text, formatted */
    va_start(s_args, pc_fmt);
    vsnprintf(ac_buf, sizeof ac_buf, pc_fmt, s_args);
    va_end(s_args);
/* USB and the FPGA's UART */
    Serial.printf("EV %s\r\n", ac_buf);
    Serial2.printf("EV %s\r\n", ac_buf);
}

/* a MAC address as text */
static void mac_str(const uint8_t *pui8_mac, char *pc_out)
{
    sprintf(pc_out, "%02x:%02x:%02x:%02x:%02x:%02x", pui8_mac[0], pui8_mac[MAC_BYTE_1], pui8_mac[MAC_BYTE_2],
            pui8_mac[MAC_BYTE_3], pui8_mac[MAC_BYTE_4], pui8_mac[MAC_BYTE_5]);
}

/* a MAC address from its text "aa:bb:cc:dd:ee:ff"; false = the text is not one */
static bool parse_mac(const char *pc_text, uint8_t *pui8_mac)
{
/* sscanf's %x needs the type unsigned int */
    unsigned int aui_value[MAC_LEN];
    int32_t i32_index;
    bool b_ok;

/* start values */
    b_ok = false;
    if (strlen(pc_text) == MAC_TEXT_LEN)
    {
        if (sscanf(pc_text, "%x:%x:%x:%x:%x:%x", &aui_value[0], &aui_value[MAC_BYTE_1], &aui_value[MAC_BYTE_2],
                   &aui_value[MAC_BYTE_3], &aui_value[MAC_BYTE_4], &aui_value[MAC_BYTE_5]) == MAC_LEN)
        {
/* the six bytes */
            for (i32_index = 0; i32_index < MAC_LEN; i32_index++)
            {
                pui8_mac[i32_index] = (uint8_t)aui_value[i32_index];
            }
            b_ok = true;
        }
    }
/* true = a MAC was read */
    return b_ok;
}

/* audio source */
/* get_frames() runs in the BT task; loop() only writes the volatile settings. */
/* The I2S clock (APLL, 44.1 kHz) and the A2DP stack's sending timer are different clocks: a few */
/* ppm apart, the DMA backlog drifts. Left alone it fills the buffers and the driver overwrites one */
/* (a 5.8 ms skip forward, heard as a short "speed-up"), or runs dry (silence). */
/* The stack takes the audio in bursts: every 30 ms tick about 1,300-1,400 frames within a few ms. So */
/* the backlog is looked at once per tick, at the first read of the burst (its highest point), and */
/* kept in [BACKLOG_LO, BACKLOG_HI] by dropping or repeating one sample frame in that tick (at most */
/* 33 frames/s = 750 ppm). The lowest point is then about 400 frames or more, the highest stays 3 */
/* buffers below the 12 the DMA has. Far outside (stream start, a hiccup): one jump back to */
/* BACKLOG_MID, by throwing frames away or by a tick or two of silence. */
/* The A2DP stack asks for audio in steady steps (~10-20 ms). A step much later than that means the */
/* sending side was held up (the speaker's buffer can run dry: a short gap); the radio side shows no */
/* late step. Counted while connected; the F3 menu shows both counters. */
/* Rate check (diagnosis, measures only): the I2S input and the A2DP stack must run at the same */
/* sample rate. Seen on hardware (2026-11-05, both speakers, some starts only): the DMA lost about */
/* every 4th buffer, ~14,000 frames/s more delivered than pulled, far beyond what the drift fix above */
/* can follow. loop() measures both rates every 2 s and keeps a history (`rates` command): the first */
/* measurements of every stream and every measurement that differs by more than 2 % from the last one */
/* kept. Changing the I2S clock automatically was tried and is wrong: when I2S delivers less, the */
/* A2DP pull rate drops too (get_frames waits for data), so the two rates are not independent. */

/* A2DP SBC codec byte 0: sampling frequency in bits 7..4 */
static uint32_t sbc_hz(uint8_t ui8_byte)
{
/* local variables */
    uint32_t ui32_hz;

/* start values */
    ui32_hz = 0;
    if ((ui8_byte & SBC_16K) != 0)
    {
        ui32_hz = HZ_16K;
    }
/* 32 kHz */
    else if ((ui8_byte & SBC_32K) != 0)
    {
        ui32_hz = HZ_32K;
    }
/* 44.1 kHz */
    else if ((ui8_byte & SBC_44K) != 0)
    {
        ui32_hz = HZ_44K;
    }
/* 48 kHz */
    else if ((ui8_byte & SBC_48K) != 0)
    {
        ui32_hz = HZ_48K;
    }
    else
    {
/* no configuration yet */
    }
    return ui32_hz;
}

/* the test tone's frequency */
static void set_tone(uint32_t ui32_hz)
{
    g_ui32_tone_hz = ui32_hz;
    g_ui32_phase_inc = (uint32_t)(((uint64_t)ui32_hz << PHASE_BITS) / SAMPLE_RATE);
}

/* the test tone's level in percent */
static void set_level(uint32_t ui32_pct)
{
    g_ui32_level_pct = ui32_pct;
    g_i32_amp = (int32_t)((ui32_pct * AMP_MAX) / PERCENT);
}

/* frames of the test tone */
static void tone_frames(Frame *ps_frames, int32_t i32_count)
{
/* local variables */
    uint32_t ui32_inc;
    int32_t i32_amp;
    int32_t i32_index;
/* a sample, the shape */
    int32_t i32_sample;
    bool b_square;

/* start values */
    ui32_inc = g_ui32_phase_inc;
    i32_amp = g_i32_amp;
    i32_sample = 0;
/* square or sine; frame by frame */
    b_square = g_b_square_wave;
    for (i32_index = 0; i32_index < i32_count; i32_index++)
    {
        i32_sample = 0;
/* a tone of 0 Hz is silence */
        if (ui32_inc != 0)
        {
            if (b_square)
            {
/* the upper half of the period is low */
                i32_sample = AMP_MAX;
                if ((g_ui32_phase & PHASE_HALF) != 0)
                {
                    i32_sample = -AMP_MAX;
                }
            }
            else
            {
/* the sine from the table */
                i32_sample = g_pi16_sine[g_ui32_phase >> SINE_PHASE_SHIFT];
            }
            i32_sample = (i32_sample * i32_amp) >> AMP_SHIFT;
            g_ui32_phase += ui32_inc;
        }
/* both channels the same */
        ps_frames[i32_index].channel2 = (int16_t)i32_sample;
        ps_frames[i32_index].channel1 = ps_frames[i32_index].channel2;
    }
}

/* throw frames of the I2S input away */
static void i2s_discard(int32_t i32_frames)
{
/* local variables */
    Frame as_junk[JUNK_FRAMES];
    size_t s_want;
/* bytes read, more to throw away */
    size_t s_read;
    bool b_more;

/* start values */
    s_want = 0;
    s_read = 0;
    b_more = true;
/* buffer by buffer */
    while ((i32_frames > 0) && b_more)
    {
/* a buffer full, or what is left */
        s_want = JUNK_FRAMES * sizeof(Frame);
        if (i32_frames < JUNK_FRAMES)
        {
            s_want = (size_t)i32_frames * sizeof(Frame);
        }
/* read and thrown away */
        s_read = 0;
        i2s_channel_read(g_s_i2s_rx, as_junk, s_want, &s_read, 0);
        g_ui32_i2s_rd_frames += s_read / sizeof(Frame);
/* that much less to do */
        i32_frames -= JUNK_FRAMES;
/* the input has no more now */
        if (s_read < s_want)
        {
            b_more = false;
        }
    }
}

/* the drift correction for a tick's first read: +1 = drop a frame, -1 = repeat one, 0 = none; */
/* far outside the range the backlog is put back in one jump (frames thrown away, or filling) */
static int32_t backlog_adjust(int32_t i32_count)
{
/* local variables */
    int32_t i32_backlog;
    int32_t i32_adjust;

/* start values */
    i32_backlog = (int32_t)(g_ui32_i2s_rx_frames - g_ui32_i2s_rd_frames);
    i32_adjust = 0;
    if (i32_backlog > (BACKLOG_HI + BACKLOG_FAR))
    {
/* far too much: throw the excess away */
        i2s_discard(i32_backlog - BACKLOG_MID);
        g_ui32_i2s_resyncs++;
    }
    else if (i32_backlog < (BACKLOG_LO - BACKLOG_FAR))
    {
/* not enough for this burst: let it fill */
        if (!g_b_filling)
        {
            g_ui32_i2s_resyncs++;
        }
/* filling */
        g_b_filling = true;
    }
    else if (g_b_filling)
    {
/* filling ends near the middle */
        if (i32_backlog >= (BACKLOG_MID - BACKLOG_NEAR))
        {
            g_b_filling = false;
        }
    }
    else if (i32_count > ADJ_MIN_FRAMES)
    {
/* inside: one frame more or less keeps it there */
        if (i32_backlog > BACKLOG_HI)
        {
            i32_adjust = YES;
        }
/* too little: one frame is repeated */
        else if (i32_backlog < BACKLOG_LO)
        {
            i32_adjust = -YES;
        }
        else
        {
/* in the range */
        }
    }
    else
    {
/* a burst too short to correct in */
    }
    return i32_adjust;
}

/* frames from the I2S input. */
/* I2S and A2DP both run from the ESP32's clocks, so on average the data is there; */
/* a short wait (at most ~8 ms) covers the DMA buffer granularity, silence beyond. */
/* b_first = the first read of a tick's burst. */
static void i2s_frames(Frame *ps_frames, int32_t i32_count, bool b_first)
{
/* local variables */
    uint8_t *pui8_dst;
    Frame s_extra;
    int32_t i32_adjust;
/* read tries, the peak, a sample's size */
    int32_t i32_tries;
    int32_t i32_peak;
    int32_t i32_abs;
/* a counter, bytes wanted */
    int32_t i32_index;
    size_t s_want;
/* bytes got, bytes of one read */
    size_t s_got;
    size_t s_read;

/* start values */
    pui8_dst = (uint8_t *)ps_frames;
    i32_adjust = 0;
    i32_tries = 0;
/* nothing measured, nothing read */
    i32_peak = 0;
    i32_abs = 0;
    s_want = 0;
/* nothing read; the first call of a tick */
    s_got = 0;
    s_read = 0;
    if (b_first)
    {
/* looks at the backlog */
        i32_adjust = backlog_adjust(i32_count);
    }
    if (g_b_filling)
    {
/* silence until the backlog is back */
        memset(pui8_dst, 0, (size_t)i32_count * sizeof(Frame));
    }
    else
    {
/* one frame less is read when one is to be repeated */
        s_want = (size_t)i32_count * sizeof(Frame);
        if (i32_adjust < 0)
        {
            s_want = (size_t)(i32_count - YES) * sizeof(Frame);
        }
/* read, with a few tries */
        while ((s_got < s_want) && (i32_tries < READ_TRIES))
        {
            s_read = 0;
            i2s_channel_read(g_s_i2s_rx, pui8_dst + s_got, s_want - s_got, &s_read, READ_WAIT_TICKS);
/* what came */
            s_got += s_read;
            i32_tries++;
        }
/* counted; too little came */
        g_ui32_i2s_rd_frames += s_got / sizeof(Frame);
        if (s_got < s_want)
        {
/* not enough data: silence for the rest */
            memset(pui8_dst + s_got, 0, s_want - s_got);
            g_ui32_i2s_underruns = g_ui32_i2s_underruns + YES;
        }
        else if (i32_adjust > 0)
        {
/* one frame dropped */
            s_read = 0;
            i2s_channel_read(g_s_i2s_rx, &s_extra, sizeof s_extra, &s_read, 0);
            if (s_read == sizeof s_extra)
            {
/* counted as read and as dropped */
                g_ui32_i2s_rd_frames += YES;
                g_ui32_i2s_drops++;
            }
        }
        else if (i32_adjust < 0)
        {
/* the last frame repeated */
            ps_frames[i32_count - YES] = ps_frames[i32_count - ADJ_MIN_FRAMES];
            g_ui32_i2s_dups++;
        }
        else
        {
/* no correction */
        }
/* the largest sample, for the status */
        i32_peak = g_i32_i2s_peak;
        for (i32_index = 0; i32_index < i32_count; i32_index++)
        {
            i32_abs = abs(ps_frames[i32_index].channel1);
/* a new peak */
            if (i32_abs > i32_peak)
            {
                i32_peak = i32_abs;
            }
        }
        g_i32_i2s_peak = i32_peak;
    }
}

/* the A2DP stack asks for frames (BT task) */
static int32_t get_frames(Frame *ps_frames, int32_t i32_count)
{
/* local variables */
    int64_t i64_now;
    uint32_t ui32_step;
    bool b_first;

/* start values */
    i64_now = esp_timer_get_time();
    ui32_step = 0;
/* longer = the stream had stopped (not a gap) */
    if ((g_i64_cb_last != 0) && ((i64_now - g_i64_cb_last) < STREAM_GAP_US))
    {
        ui32_step = (uint32_t)(i64_now - g_i64_cb_last);
/* the longest step */
        if (ui32_step > g_ui32_cb_max_us)
        {
            g_ui32_cb_max_us = ui32_step;
        }
/* late calls counted */
        if (ui32_step > LATE_US)
        {
            g_ui32_cb_late = g_ui32_cb_late + YES;
        }
    }
/* the calls of one tick follow each other within a few ms */
    b_first = (g_i64_cb_last == 0) || ((i64_now - g_i64_cb_last) > TICK_GAP_US);
    g_i64_cb_last = i64_now;
    g_ui32_a2dp_req = g_ui32_a2dp_req + i32_count;
/* the frames: from the FPGA or the test tone */
    if (g_b_src_i2s)
    {
        i2s_frames(ps_frames, i32_count, b_first);
    }
    else
    {
        tone_frames(ps_frames, i32_count);
    }
/* muted: silence instead */
    if (g_b_muted)
    {
        memset(ps_frames, 0, (size_t)i32_count * sizeof(Frame));
    }
    return i32_count;
}

/* the DMA delivered a buffer (ISR) */
static bool IRAM_ATTR i2s_on_recv(i2s_chan_handle_t s_chan, i2s_event_data_t *ps_event, void *p_arg)
{
    (void)s_chan;
    (void)p_arg;
/* frames received, in the buffer and in total */
    g_ui32_i2s_rx_frames = g_ui32_i2s_rx_frames + (ps_event->size / sizeof(Frame));
    g_ui32_i2s_gross = g_ui32_i2s_gross + (ps_event->size / sizeof(Frame));
    return false;
}

/* the DMA overwrote a buffer (ISR): that buffer is gone */
static bool IRAM_ATTR i2s_on_ovf(i2s_chan_handle_t s_chan, i2s_event_data_t *ps_event, void *p_arg)
{
/* local variables */
    size_t s_bytes;

    (void)s_chan;
    (void)p_arg;
/* the event says how much, else it was one DMA buffer */
    s_bytes = DMA_LEN * sizeof(Frame);
    if ((ps_event != nullptr) && (ps_event->size != 0))
    {
        s_bytes = ps_event->size;
    }
/* counted; those frames are not in the buffer */
    g_ui32_i2s_overflows = g_ui32_i2s_overflows + YES;
    g_ui32_i2s_rx_frames = g_ui32_i2s_rx_frames - (s_bytes / sizeof(Frame));
    return false;
}

/* start the I2S input: the ESP32 is the master */
static void i2s_start(void)
{
/* local variables */
    i2s_chan_config_t s_chan = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
    i2s_std_config_t s_cfg =
    {
/* the sample clock and the slot format, as the FPGA sends them */
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO),
        .gpio_cfg =
        {
/* the pins: only clocks out and data in */
            .mclk = I2S_GPIO_UNUSED,
            .bclk = (gpio_num_t)I2S_BCLK,
            .ws = (gpio_num_t)I2S_LRCK,
            .dout = I2S_GPIO_UNUSED,
            .din = (gpio_num_t)I2S_DIN,
            .invert_flags = { false, false, false },
        },
    };
    i2s_event_callbacks_t s_callbacks = {};

/* the DMA's size */
    s_chan.dma_desc_num = DMA_BUFS;
    s_chan.dma_frame_num = DMA_LEN;
    ESP_ERROR_CHECK(i2s_new_channel(&s_chan, nullptr, &g_s_i2s_rx));
/* exact 44.1 kHz */
    s_cfg.clk_cfg.clk_src = I2S_CLK_SRC_APLL;
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(g_s_i2s_rx, &s_cfg));
/* the two callbacks count the frames */
    s_callbacks.on_recv = i2s_on_recv;
    s_callbacks.on_recv_q_ovf = i2s_on_ovf;
    ESP_ERROR_CHECK(i2s_channel_register_event_callback(g_s_i2s_rx, &s_callbacks, nullptr));
/* silence when the FPGA is not connected */
    gpio_pulldown_en((gpio_num_t)I2S_DIN);
    ESP_ERROR_CHECK(i2s_channel_enable(g_s_i2s_rx));
}

/* devices found */
/* on_found() runs in the BT task during discovery; loop() prints new entries. */

/* is this device the target (by MAC or by exact name)? */
static bool is_target(const char *pc_name, const uint8_t *pui8_mac)
{
/* local variables */
    uint8_t aui8_target[MAC_LEN];
    bool b_hit;

/* start values */
    b_hit = false;
    if (g_ac_target[0] != 0)
    {
        if (parse_mac(g_ac_target, aui8_target))
        {
/* the target is a MAC */
            b_hit = memcmp(aui8_target, pui8_mac, MAC_LEN) == 0;
        }
        else
        {
/* or a name */
            b_hit = (pc_name[0] != 0) && (strcasecmp(g_ac_target, pc_name) == 0);
        }
    }
    return b_hit;
}

/* is this device in the list already? */
static bool dev_known(const uint8_t *pui8_mac)
{
/* local variables */
    int32_t i32_index;
    bool b_known;

/* start values */
    b_known = false;
    portENTER_CRITICAL(&g_s_devs_mux);
    for (i32_index = 0; i32_index < g_i32_ndevs; i32_index++)
    {
/* the same MAC */
        if (memcmp(g_as_devs[i32_index].aui8_mac, pui8_mac, MAC_LEN) == 0)
        {
            b_known = true;
        }
    }
/* the list is free again */
    portEXIT_CRITICAL(&g_s_devs_mux);
    return b_known;
}

/* Records a device seen by discovery; true = it is the target, connect to it. */
/* A device without a name in the inquiry result gets one later from the name */
/* request (or never): it is then reported again. */
static bool on_found(const char *pc_name, const uint8_t *pui8_mac, int32_t i32_rssi)
{
/* local variables */
    int32_t i32_index;
    bool b_hit;

/* start values */
    i32_index = 0;
    portENTER_CRITICAL(&g_s_devs_mux);
/* its place in the list, or the first free one */
    while ((i32_index < g_i32_ndevs) && (memcmp(g_as_devs[i32_index].aui8_mac, pui8_mac, MAC_LEN) != 0))
    {
        i32_index++;
    }
/* a new device, if the list has room */
    if ((i32_index == g_i32_ndevs) && (g_i32_ndevs < MAX_DEVS))
    {
        g_i32_ndevs++;
        memcpy(g_as_devs[i32_index].aui8_mac, pui8_mac, MAC_LEN);
/* no name, no signal strength, not reported yet */
        g_as_devs[i32_index].ac_name[0] = 0;
        g_as_devs[i32_index].i32_rssi = RSSI_UNKNOWN;
        g_as_devs[i32_index].b_reported = false;
    }
/* a new name is reported again; a known signal strength is kept */
    if (i32_index < g_i32_ndevs)
    {
        if ((pc_name[0] != 0) && (strcmp(g_as_devs[i32_index].ac_name, pc_name) != 0))
        {
            strlcpy(g_as_devs[i32_index].ac_name, pc_name, sizeof g_as_devs[i32_index].ac_name);
/* to be reported; the signal strength */
            g_as_devs[i32_index].b_reported = false;
        }
        if (i32_rssi != RSSI_UNKNOWN)
        {
            g_as_devs[i32_index].i32_rssi = i32_rssi;
        }
    }
/* the list is free again */
    portEXIT_CRITICAL(&g_s_devs_mux);
/* the target's name is remembered */
    b_hit = g_b_want_connect && is_target(pc_name, pui8_mac);
    if (b_hit && (pc_name[0] != 0))
    {
        strlcpy(g_ac_peer_name, pc_name, sizeof g_ac_peer_name);
    }
/* true = this is the device to connect to */
    return b_hit;
}

/* A2DP source */
/* Adds to the library: pairing with legacy PIN devices (and events about it), */
/* discovery of devices that only give their name by name request (BT 2.0, the */
/* PIN ones), no discovery while connected, and the SBC encoder fix above. */
class ZxA2DP : public BluetoothA2DPSource
{
public:
/* the result of setting the transmit power */
    static esp_err_t s_e_tx_power_err;

/* The library (1.8.11) starts the stream once per connection: a sink that suspends it (Bose */
/* headphones did, 1-2 s after connecting during a tape load) leaves the link "connected" with */
/* no audio pulled, for good. Its media state back to idle makes the heart beat (1 s) check and */
/* start the stream again. Called by loop() when no audio was asked for 3 s while connected. */
    bool kick_media()
    {
        bool b_kicked;

        b_kicked = false;
/* only a started stream (not one starting / stopping) */
        if (s_media_state == MEDIA_STARTED)
        {
            s_media_state = MEDIA_IDLE;
            g_ui32_media_restarts = g_ui32_media_restarts + YES;
/* kicked */
            b_kicked = true;
        }
        return b_kicked;
    }

/* the library's media state */
    int32_t media_state()
    {
        return s_media_state;
    }

/* BR/EDR transmit power: the controller's default range is 0..+3 dBm; +9 dBm is the ESP32's */
/* maximum (2026-11-05, weak link: RSSI delta about -20). ESP-IDF wants it after the controller is */
/* enabled and before any RF use, which is exactly the library's bt_start() (then Bluedroid starts). */
    bool bt_start() override
    {
        bool b_ok;

/* the library's start first */
        b_ok = BluetoothA2DPSource::bt_start();
        if (b_ok)
        {
/* the transmit power */
            s_e_tx_power_err = esp_bredr_tx_power_set(ESP_PWR_LVL_N0, ESP_PWR_LVL_P9);
        }
        return b_ok;
    }

/* set_pin_code() copies with strcpy into a 16-byte array: a 16-digit PIN overflows */
    void use_pin(const char *pc_pin)
    {
        size_t s_len;

/* at most 16 characters */
        s_len = strlen(pc_pin);
        if (s_len > ESP_BT_PIN_CODE_LEN)
        {
            s_len = ESP_BT_PIN_CODE_LEN;
        }
/* the rest stays 0 */
        memset(pin_code, 0, sizeof pin_code);
        memcpy(pin_code, pc_pin, s_len);
/* the library replies with these */
        pin_code_len = s_len;
        pin_type = ESP_BT_PIN_TYPE_VARIABLE;
    }

protected:
/* a PIN was asked for in this pairing */
    bool b_pin_asked = false;

/* a legacy device asks for a PIN: the fixed one, or the next of the list */
    void pin_request(esp_bt_gap_cb_param_t *ps_param)
    {
        char ac_pin[PIN_BUF];

/* which PIN */
        if (g_ac_pin_fixed[0] != 0)
        {
            strlcpy(ac_pin, g_ac_pin_fixed, sizeof ac_pin);
        }
        else
        {
            strlcpy(ac_pin, g_apc_auto_pins[g_i32_pin_try % N_AUTO_PINS], sizeof ac_pin);
        }
/* pad to 16 digits with zeros */
        if (ps_param->pin_req.min_16_digit)
        {
            while (strlen(ac_pin) < PIN_LEN)
            {
                strcat(ac_pin, "0");
            }
        }
/* the library answers with it */
        use_pin(ac_pin);
        b_pin_asked = true;
        event("pairing pin %s", ac_pin);
    }

/* the end of a pairing */
    void auth_complete(esp_bt_gap_cb_param_t *ps_param)
    {
        if (ps_param->auth_cmpl.stat == ESP_BT_STATUS_SUCCESS)
        {
            event("paired %s", (const char *)ps_param->auth_cmpl.device_name);
        }
        else
        {
/* failed */
            event("pairing failed (status %d)", ps_param->auth_cmpl.stat);
/* a wrong PIN from the list: the next one at the next try */
            if (b_pin_asked && (g_ac_pin_fixed[0] == 0))
            {
                g_i32_pin_try = (g_i32_pin_try + YES) % N_AUTO_PINS;
                event("pairing next try with pin %s", g_apc_auto_pins[g_i32_pin_try]);
            }
        }
/* the next pairing starts fresh */
        b_pin_asked = false;
    }

/* GAP events: pairing, RSSI, discovery */
    void app_gap_callback(esp_bt_gap_cb_event_t e_event, esp_bt_gap_cb_param_t *ps_param) override
    {
        bool b_pass;

/* the library's handler runs afterwards, except for one event */
        b_pass = true;
        switch (e_event)
        {
        case ESP_BT_GAP_PIN_REQ_EVT:
/* the library replies with pin_code */
            pin_request(ps_param);
            break;
/* a numeric comparison: accepted */
        case ESP_BT_GAP_CFM_REQ_EVT:
            event("pairing confirm %06u (accepted)", (unsigned)ps_param->cfm_req.num_val);
            break;
/* a passkey to type on the other device */
        case ESP_BT_GAP_KEY_NOTIF_EVT:
            event("pairing passkey %06u", (unsigned)ps_param->key_notif.passkey);
            break;
/* the end of a pairing */
        case ESP_BT_GAP_AUTH_CMPL_EVT:
            auth_complete(ps_param);
            break;
/* the signal strength that was asked for */
        case ESP_BT_GAP_READ_RSSI_DELTA_EVT:
            if (ps_param->read_rssi_delta.stat == ESP_BT_STATUS_SUCCESS)
            {
                g_i8_link_rssi = ps_param->read_rssi_delta.rssi_delta;
/* reads counted */
                g_ui32_rssi_reads = g_ui32_rssi_reads + YES;
            }
            break;
        case ESP_BT_GAP_DISC_STATE_CHANGED_EVT:
/* The library restarts discovery whenever it stops without a find, even */
/* while connected; inquiry during streaming costs radio time. */
            if (g_b_link_up && (ps_param->disc_st_chg.state == ESP_BT_GAP_DISCOVERY_STOPPED))
            {
                discovery_active = false;
/* not passed to the library */
                b_pass = false;
            }
            break;
        default:
/* the library's business */
            break;
        }
/* everything else goes to the library */
        if (b_pass)
        {
            BluetoothA2DPSource::app_gap_callback(e_event, ps_param);
        }
    }

/* A2DP events: the audio state, the link */
    void app_a2d_callback(esp_a2d_cb_event_t e_event, esp_a2d_cb_param_t *ps_param) override
    {
        if (e_event == ESP_A2D_AUDIO_STATE_EVT)
        {
            g_i32_audio_state = ps_param->audio_stat.state;
/* counted */
            g_ui32_audio_events = g_ui32_audio_events + YES;
        }
/* the codec set up for this connection */
        if (e_event == ESP_A2D_AUDIO_CFG_EVT)
        {
            g_ui8_sbc_cfg = ((const uint8_t *)&ps_param->audio_cfg.mcc.cie)[0];
            g_ui32_cfg_events = g_ui32_cfg_events + YES;
        }
/* the link came up or went down; no search while it is up */
        if (e_event == ESP_A2D_CONNECTION_STATE_EVT)
        {
            if (ps_param->conn_stat.state == ESP_A2D_CONNECTION_STATE_CONNECTED)
            {
                g_b_link_up = true;
/* a search that still runs is stopped */
                if (discovery_active)
                {
                    esp_bt_gap_cancel_discovery();
                }
            }
/* down */
            else if (ps_param->conn_stat.state == ESP_A2D_CONNECTION_STATE_DISCONNECTED)
            {
                g_b_link_up = false;
            }
            else
            {
/* connecting or disconnecting */
            }
        }
        BluetoothA2DPSource::app_a2d_callback(e_event, ps_param);
    }

/* As the library's, but a name may also come as BDNAME (name request result, */
/* BT 2.0 devices have no EIR) or not at all (then connect by MAC). */
    void filter_inquiry_scan_result(esp_bt_gap_cb_param_t *ps_param) override
    {
/* class of device, and whether it is an audio device */
        uint32_t ui32_cod;
        bool b_has_cod;
        bool b_audio;
/* signal strength, a counter, the name's length */
        int32_t i32_rssi;
        int32_t i32_index;
        int32_t i32_len;
/* the EIR data, a property, the name */
        uint8_t *pui8_eir;
        esp_bt_gap_dev_prop_t *ps_prop;
        char ac_name[BDNAME_BUF] = "";

/* start values */
        ui32_cod = 0;
        b_has_cod = false;
        b_audio = false;
/* no signal strength known */
        i32_rssi = RSSI_UNKNOWN;
        i32_len = 0;
/* no EIR data, no property yet */
        pui8_eir = nullptr;
        ps_prop = nullptr;
/* the properties of the result */
        for (i32_index = 0; i32_index < ps_param->disc_res.num_prop; i32_index++)
        {
            ps_prop = ps_param->disc_res.prop + i32_index;
            switch (ps_prop->type)
            {
/* the class of device */
            case ESP_BT_GAP_DEV_PROP_COD:
                ui32_cod = *(uint32_t *)ps_prop->val;
/* seen */
                b_has_cod = true;
                break;
/* the signal strength */
            case ESP_BT_GAP_DEV_PROP_RSSI:
                i32_rssi = *(int8_t *)ps_prop->val;
                break;
/* the extended inquiry response */
            case ESP_BT_GAP_DEV_PROP_EIR:
                pui8_eir = (uint8_t *)ps_prop->val;
                break;
/* the name */
            case ESP_BT_GAP_DEV_PROP_BDNAME:
/* the name, cut to the buffer */
                i32_len = ESP_BT_GAP_MAX_BDNAME_LEN;
                if (ps_prop->len < ESP_BT_GAP_MAX_BDNAME_LEN)
                {
                    i32_len = ps_prop->len;
                }
/* copied */
                memcpy(ac_name, ps_prop->val, i32_len);
/* terminated */
                ac_name[i32_len] = 0;
                break;
            default:
/* a property not used here */
                break;
            }
        }
        if ((ac_name[0] == 0) && (pui8_eir != nullptr))
        {
            get_name_from_eir(pui8_eir, (uint8_t *)ac_name, nullptr);
        }
/* an audio device: by its class, or (a result without a class) one seen before */
        if (b_has_cod)
        {
            b_audio = esp_bt_gap_is_valid_cod(ui32_cod) && is_valid_cod_service(ui32_cod);
        }
        else
        {
            b_audio = dev_known(ps_param->disc_res.bda);
        }
/* audio devices go into the list */
        if (b_audio)
        {
/* the target: the library connects when the search stops */
            if (on_found(ac_name, ps_param->disc_res.bda, i32_rssi))
            {
                strlcpy((char *)s_peer_bdname, ac_name, sizeof s_peer_bdname);
                s_a2d_state = APP_AV_STATE_DISCOVERED;
/* its address, kept for the next start */
                memcpy(peer_bd_addr, ps_param->disc_res.bda, ESP_BD_ADDR_LEN);
                set_last_connection(peer_bd_addr);
                esp_bt_gap_cancel_discovery();
            }
        }
    }
};

/* the A2DP source */
ZxA2DP g_s_a2dp;
esp_err_t ZxA2DP::s_e_tx_power_err = ESP_FAIL;

/* status */

/* the name of a connection state */
static const char *conn_name(esp_a2d_connection_state_t e_state)
{
/* local variables */
    const char *pc_name;

    switch (e_state)
    {
    case ESP_A2D_CONNECTION_STATE_DISCONNECTED:
/* no link */
        pc_name = "disconnected";
        break;
    case ESP_A2D_CONNECTION_STATE_CONNECTING:
/* on the way up */
        pc_name = "connecting";
        break;
    case ESP_A2D_CONNECTION_STATE_CONNECTED:
/* up */
        pc_name = "connected";
        break;
    case ESP_A2D_CONNECTION_STATE_DISCONNECTING:
/* on the way down */
        pc_name = "disconnecting";
        break;
    default:
/* a state the library does not document */
        pc_name = "?";
        break;
    }
    return pc_name;
}

/* a text, or a stand-in when it is empty */
static const char *or_text(const char *pc_text, const char *pc_empty)
{
/* local variables */
    const char *pc_result;

/* start values */
    pc_result = pc_empty;
    if (pc_text[0] != 0)
    {
/* the text itself */
        pc_result = pc_text;
    }
    return pc_result;
}

/* "on" or "off" */
static const char *on_off(bool b_on)
{
/* local variables */
    const char *pc_result;

/* start values */
    pc_result = "off";
    if (b_on)
    {
/* on */
        pc_result = "on";
    }
    return pc_result;
}

/* the devices found so far */
static void list_devs(Print &r_out)
{
/* local variables */
    Dev as_copy[MAX_DEVS];
    char ac_mac[MAC_BUF];
/* the number of devices, a counter */
    int32_t i32_count;
    int32_t i32_index;

/* a copy, so that the BT task is not held while printing */
    portENTER_CRITICAL(&g_s_devs_mux);
    i32_count = g_i32_ndevs;
    memcpy(as_copy, g_as_devs, sizeof as_copy);
/* the BT task may go on */
    portEXIT_CRITICAL(&g_s_devs_mux);
    r_out.printf("OK %d device(s)\r\n", (int)i32_count);
    for (i32_index = 0; i32_index < i32_count; i32_index++)
    {
/* its address, signal strength and name */
        mac_str(as_copy[i32_index].aui8_mac, ac_mac);
        r_out.printf("%2d %s %4d %s\r\n", (int)i32_index, ac_mac, (int)as_copy[i32_index].i32_rssi,
                     or_text(as_copy[i32_index].ac_name, "(no name)"));
    }
}

/* everything about the connection and the audio */
static void status(Print &r_out)
{
/* local variables */
    char ac_mac[MAC_BUF];
    uint8_t aui8_cie[CIE_LEN] = { 0 };
    uint16_t ui16_mtu;
/* the transmit power range */
    esp_power_level_t e_low;
    esp_power_level_t e_high;
/* ms since audio was asked for; a text */
    long l_since_audio;
    const char *pc_text;

/* start values */
    ui16_mtu = 0;
    e_low = ESP_PWR_LVL_N0;
    e_high = ESP_PWR_LVL_N0;
/* not known; no text */
    l_since_audio = NO_NUMBER;
    pc_text = "";
/* connection */
    mac_str(*g_s_a2dp.get_last_peer_address(), ac_mac);
    r_out.printf("OK state=%s peer=%s (%s) discovery=%s\r\n", conn_name(g_s_a2dp.get_connection_state()), ac_mac,
                 or_text(g_ac_peer_name, "-"), on_off(g_s_a2dp.is_discovery_active()));
/* target and PIN */
    if (g_ac_pin_fixed[0] != 0)
    {
        r_out.printf("   target=%s autoconnect=%s pin=%s\r\n", or_text(g_ac_target, "-"), on_off(g_b_want_connect),
                     g_ac_pin_fixed);
    }
    else
    {
        r_out.printf("   target=%s autoconnect=%s pin=auto (next %s)\r\n", or_text(g_ac_target, "-"),
                     on_off(g_b_want_connect), g_apc_auto_pins[g_i32_pin_try]);
    }
/* source and tone */
    pc_text = "tone";
    if (g_b_src_i2s)
    {
        pc_text = "i2s";
    }
/* source, volume, the input's peak */
    r_out.printf("   src=%s vol=%u mute=%s i2s: peak=%d underruns=%u\r\n", pc_text, (unsigned)g_ui32_volume,
                 on_off(g_b_muted), (int)g_i32_i2s_peak, (unsigned)g_ui32_i2s_underruns);
/* the test tone's shape */
    pc_text = "sine";
    if (g_b_square_wave)
    {
        pc_text = "square";
    }
/* the tone, and the codec fix */
    r_out.printf("   tone=%u Hz wave=%s level=%u%% codec-fix=%u\r\n", (unsigned)g_ui32_tone_hz, pc_text,
                 (unsigned)g_ui32_level_pct, (unsigned)g_ui32_codec_forced);
/* the stream */
    r_out.printf("   audio steps: late=%u (> %u ms) longest=%u ms\r\n", (unsigned)g_ui32_cb_late,
                 (unsigned)(LATE_US / US_PER_MS), (unsigned)(g_ui32_cb_max_us / US_PER_MS));
    if (g_i64_cb_last != 0)
    {
        l_since_audio = (long)((esp_timer_get_time() - g_i64_cb_last) / US_PER_MS);
    }
/* the stream's state */
    r_out.printf("   stream: media state %d, audio state %d (%u events), restarts=%u, relinks=%u, last audio %ld ms ago\r\n",
                 (int)g_s_a2dp.media_state(), (int)g_i32_audio_state, (unsigned)g_ui32_audio_events,
                 (unsigned)g_ui32_media_restarts, (unsigned)g_ui32_relinks, l_since_audio);
/* the I2S input and the rates */
    r_out.printf("   i2s backlog=%d frames, overflows=%u, drift fixes: dropped=%u repeated=%u, resyncs=%u\r\n",
                 (int)(g_ui32_i2s_rx_frames - g_ui32_i2s_rd_frames), (unsigned)g_ui32_i2s_overflows,
                 (unsigned)g_ui32_i2s_drops, (unsigned)g_ui32_i2s_dups, (unsigned)g_ui32_i2s_resyncs);
    r_out.printf("   rates: i2s %u Hz, a2dp %u Hz, codec %u Hz (0x%02x, %u cfg events), history %u (`rates`)\r\n",
                 (unsigned)g_ui32_meas_i2s_hz, (unsigned)g_ui32_meas_a2dp_hz, (unsigned)sbc_hz(g_ui8_sbc_cfg),
                 (unsigned)g_ui8_sbc_cfg, (unsigned)g_ui32_cfg_events, (unsigned)g_ui32_rate_log_n);
/* the link */
    pc_text = "config";
    if (g_b_bp_from_peer)
    {
        pc_text = "sink";
    }
/* signal strength and bitpool */
    r_out.printf("   link: rssi delta %d (%u reads), bitpool %u..%u from the %s, cap %u -> max %u (%u calls)\r\n",
                 (int)g_i8_link_rssi, (unsigned)g_ui32_rssi_reads, (unsigned)g_ui8_bp_peer_min,
                 (unsigned)g_ui8_bp_peer_max, pc_text, (unsigned)g_ui8_bitpool_cap, (unsigned)g_ui8_bp_max,
                 (unsigned)g_ui32_bp_calls);
/* media packets; the largest ones are counted from here again */
    bta_av_co_audio_get_sbc_config(aui8_cie, &ui16_mtu);
    r_out.printf("   packets: %u/s with %u frames/s, largest %u frames / %u bytes, mtu %u, write errors %u, total %u\r\n",
                 (unsigned)g_ui32_meas_pk_hz, (unsigned)g_ui32_meas_pkfr_hz, (unsigned)g_ui16_pk_max_frames,
                 (unsigned)g_ui16_pk_max_len, (unsigned)ui16_mtu, (unsigned)g_ui32_pk_err, (unsigned)g_ui32_pk_n);
/* counted from here again */
    g_ui16_pk_max_frames = 0;
    g_ui16_pk_max_len = 0;
/* Each media packet is a 4112-byte buffer from the internal heap (osi_malloc, BTC_MEDIA_AA_BUF_SIZE); */
/* a tick that needs two packets needs two such blocks at once. */
    r_out.printf("   heap: free %u, largest block %u, lowest free ever %u (internal RAM)\r\n",
                 (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL),
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL),
                 (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL));
    r_out.printf("   l2cap: %u buffers waiting (max %u, %u queries), dropped packets %u, acl links %u\r\n",
                 (unsigned)g_ui16_l2c_last, (unsigned)g_ui16_l2c_max, (unsigned)g_ui32_l2c_calls,
                 (unsigned)g_ui32_co_drops, (unsigned)BTM_GetNumAclLinks());
    g_ui16_l2c_max = 0;
/* role, mode, transmit power */
    r_out.printf("   role: %s, mode %s (changes %u)\r\n", role_name(g_ui8_link_role), mode_name(g_ui8_link_mode),
                 (unsigned)g_ui32_role_changes);
    esp_bredr_tx_power_get(&e_low, &e_high);
/* was the power set? */
    pc_text = "ok";
    if (ZxA2DP::s_e_tx_power_err != ESP_OK)
    {
        pc_text = esp_err_to_name(ZxA2DP::s_e_tx_power_err);
    }
/* the range in dBm */
    r_out.printf("   tx power: %d..%d dBm (set: %s)\r\n", g_ai8_dbm[e_low & DBM_LEVEL_MASK],
                 g_ai8_dbm[e_high & DBM_LEVEL_MASK], pc_text);
/* the peak is measured from here again */
    g_i32_i2s_peak = 0;
}

/* commands */

/* start a search, unless one runs */
static void start_discovery(void)
{
    if (!g_s_a2dp.is_discovery_active())
    {
        esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, INQUIRY_LEN, 0);
/* when it started */
        g_ui32_last_kick = millis();
    }
}

/* the list of commands */
static void help(Print &r_out)
{
    r_out.print(
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

/* "rates": the sample rate history */
static void cmd_rates(Print &r_out)
{
/* local variables */
    const RateLog *ps_entry;
    uint32_t ui32_count;
    uint32_t ui32_index;

/* start values */
    ps_entry = g_as_rate_log;
/* the last entries the ring holds */
    ui32_count = RATE_LOG_LEN;
    if (g_ui32_rate_log_n < RATE_LOG_LEN)
    {
        ui32_count = g_ui32_rate_log_n;
    }
/* the header */
    r_out.printf("OK rates: %u entries (ms since start, i2s Hz, a2dp Hz, overflows, drift fixes, rssi delta, bitpool, role, mode)\r\n",
                 (unsigned)g_ui32_rate_log_n);
    for (ui32_index = g_ui32_rate_log_n - ui32_count; ui32_index < g_ui32_rate_log_n; ui32_index++)
    {
        ps_entry = &g_as_rate_log[ui32_index % RATE_LOG_LEN];
/* one line per entry */
        r_out.printf("   %8u %6u %6u %8u %8u %4d %3u %s %s\r\n", (unsigned)ps_entry->ui32_ms, (unsigned)ps_entry->ui32_i2s_hz,
                     (unsigned)ps_entry->ui32_a2dp_hz, (unsigned)ps_entry->ui32_ovf, (unsigned)ps_entry->ui32_fix,
                     (int)ps_entry->i8_rssi, (unsigned)ps_entry->ui8_bitpool, role_name(ps_entry->ui8_role),
                     mode_name(ps_entry->ui8_mode));
    }
}

/* "info": one line for the F3 menu */
static void cmd_info(Print &r_out)
{
/* local variables */
    char ac_mac[MAC_BUF];
    const char *pc_scan;
    const char *pc_src;

/* start values */
    pc_scan = "idle";
    pc_src = "tone";
    mac_str(*g_s_a2dp.get_last_peer_address(), ac_mac);
/* searching */
    if (g_s_a2dp.is_discovery_active() || g_b_scan_pending)
    {
        pc_scan = "scan";
    }
/* the source */
    if (g_b_src_i2s)
    {
        pc_src = "i2s";
    }
/* one line, in the order the menu reads it */
    r_out.printf("OK info %s %s %s %u %s %s %u %u %u %u %u %u %s\r\n", conn_name(g_s_a2dp.get_connection_state()), pc_scan,
                 ac_mac, (unsigned)g_ui32_volume, or_text(g_ac_pin_fixed, "auto"), pc_src, (unsigned)g_ui32_i2s_underruns,
                 (unsigned)g_ui32_i2s_overflows, (unsigned)(g_ui32_i2s_drops + g_ui32_i2s_dups),
                 (unsigned)g_ui32_meas_i2s_hz, (unsigned)g_ui32_meas_a2dp_hz, (unsigned)g_ui32_rate_log_n,
                 or_text(g_ac_peer_name, "-"));
}

/* "scan": drop the link and search */
static void cmd_scan(Print &r_out)
{
/* an empty list */
    portENTER_CRITICAL(&g_s_devs_mux);
    g_i32_ndevs = 0;
    portEXIT_CRITICAL(&g_s_devs_mux);
/* a link is up */
    if (g_s_a2dp.get_connection_state() != ESP_A2D_CONNECTION_STATE_DISCONNECTED)
    {
/* looking for another device: drop this one first */
        g_b_want_connect = false;
        g_s_a2dp.disconnect();
        g_b_scan_pending = true;
    }
    else
    {
/* no link: search at once */
        start_discovery();
    }
    r_out.print("OK scanning\r\n");
}

/* "connect <n|MAC|name>" */
static void cmd_connect(const char *pc_arg, Print &r_out)
{
/* local variables */
    char *pc_end;
    long l_number;
    bool b_ok;

/* start values */
    pc_end = nullptr;
    l_number = 0;
    b_ok = true;
/* an argument is needed */
    if (pc_arg == nullptr)
    {
        r_out.print("ERR connect <n|MAC|name>\r\n");
        b_ok = false;
    }
    else
    {
/* a number is an index of the list, anything else a MAC or a name */
        l_number = strtol(pc_arg, &pc_end, DECIMAL);
        if ((*pc_end == 0) && (l_number >= 0))
        {
            if (l_number >= g_i32_ndevs)
            {
/* no such index */
                r_out.print("ERR no such device, see list\r\n");
                b_ok = false;
            }
            else
            {
/* its MAC is the target, its name is known */
                mac_str(g_as_devs[l_number].aui8_mac, g_ac_target);
                strlcpy(g_ac_peer_name, g_as_devs[l_number].ac_name, sizeof g_ac_peer_name);
            }
        }
        else
        {
/* a MAC or a name */
            strlcpy(g_ac_target, pc_arg, sizeof g_ac_target);
        }
    }
    if (b_ok)
    {
/* the target is stored */
        g_s_prefs.putString("target", g_ac_target);
        g_b_want_connect = true;
/* a link to another device is dropped first; the search finds the target */
        if (g_s_a2dp.get_connection_state() == ESP_A2D_CONNECTION_STATE_CONNECTED)
        {
            g_s_a2dp.disconnect();
        }
        else
        {
            start_discovery();
        }
/* said */
        r_out.printf("OK connecting to %s\r\n", g_ac_target);
    }
}

/* "forget": no target, no stored peer, no pairing */
static void cmd_forget(Print &r_out)
{
/* local variables */
    uint8_t aui8_target[MAC_LEN];

/* the pairing with the target */
    if (parse_mac(g_ac_target, aui8_target))
    {
        esp_bt_gap_remove_bond_device(aui8_target);
    }
/* and with the last device */
    esp_bt_gap_remove_bond_device(*g_s_a2dp.get_last_peer_address());
    g_b_want_connect = false;
/* no target, no name */
    g_ac_target[0] = 0;
    g_ac_peer_name[0] = 0;
/* and from the stored settings */
    g_s_prefs.remove("target");
    g_s_a2dp.clean_last_connection();
    r_out.print("OK\r\n");
}

/* "pin auto|<code>" */
static void cmd_pin(const char *pc_arg, Print &r_out)
{
/* local variables */
    bool b_ok;

/* start values */
    b_ok = true;
    if ((pc_arg != nullptr) && (strcasecmp(pc_arg, "auto") == 0))
    {
/* the list of usual PINs again */
        g_ac_pin_fixed[0] = 0;
        g_i32_pin_try = 0;
    }
    else if ((pc_arg != nullptr) && (strlen(pc_arg) <= PIN_LEN))
    {
/* a fixed PIN */
        strlcpy(g_ac_pin_fixed, pc_arg, sizeof g_ac_pin_fixed);
    }
    else
    {
/* too long, or missing */
        r_out.print("ERR pin auto|<1..16 chars>\r\n");
        b_ok = false;
    }
/* stored */
    if (b_ok)
    {
        g_s_prefs.putString("pin", g_ac_pin_fixed);
        r_out.print("OK\r\n");
    }
}

/* a command with two words to choose from: 1 = the first, 0 = the second, NO_NUMBER = neither */
static int32_t two_words(const char *pc_arg, const char *pc_first, const char *pc_second)
{
/* local variables */
    int32_t i32_result;

/* start values */
    i32_result = NO_NUMBER;
    if (pc_arg != nullptr)
    {
        if (strcasecmp(pc_arg, pc_first) == 0)
        {
/* the first word */
            i32_result = YES;
        }
        else if (strcasecmp(pc_arg, pc_second) == 0)
        {
            i32_result = 0;
        }
        else
        {
/* another word */
        }
    }
    return i32_result;
}

/* the number of an argument, NO_NUMBER if there is none */
static long arg_number(const char *pc_arg)
{
/* local variables */
    long l_value;

/* start values */
    l_value = NO_NUMBER;
    if (pc_arg != nullptr)
    {
/* the argument as a number */
        l_value = atol(pc_arg);
    }
    return l_value;
}

/* the commands that set a value */
static void cmd_setting(const char *pc_cmd, const char *pc_arg, Print &r_out)
{
/* local variables */
    long l_value;
    int32_t i32_choice;

/* start values */
    l_value = arg_number(pc_arg);
    i32_choice = NO_NUMBER;
/* the audio source */
    if (strcasecmp(pc_cmd, "src") == 0)
    {
        i32_choice = two_words(pc_arg, "i2s", "tone");
        if (i32_choice == NO_NUMBER)
        {
/* neither word */
            r_out.print("ERR src i2s|tone\r\n");
        }
        else
        {
/* set, stored, confirmed */
            g_b_src_i2s = i32_choice != 0;
            g_s_prefs.putBool("i2s", g_b_src_i2s);
            r_out.print("OK\r\n");
        }
    }
/* the test tone's frequency */
    else if (strcasecmp(pc_cmd, "tone") == 0)
    {
        if ((l_value < 0) || ((l_value > 0) && (l_value < TONE_MIN)) || (l_value > TONE_MAX))
        {
            r_out.print("ERR tone <0|20..20000>\r\n");
        }
        else
        {
/* set, stored, confirmed */
            set_tone(l_value);
            g_s_prefs.putUInt("tone", l_value);
            r_out.print("OK\r\n");
        }
    }
/* the test tone's shape */
    else if (strcasecmp(pc_cmd, "wave") == 0)
    {
        i32_choice = two_words(pc_arg, "square", "sine");
        if (i32_choice == NO_NUMBER)
        {
/* neither word */
            r_out.print("ERR wave sine|square\r\n");
        }
        else
        {
/* set, stored, confirmed */
            g_b_square_wave = i32_choice != 0;
            g_s_prefs.putBool("square", g_b_square_wave);
            r_out.print("OK\r\n");
        }
    }
/* the test tone's level */
    else if (strcasecmp(pc_cmd, "level") == 0)
    {
        if ((l_value < 0) || (l_value > LEVEL_MAX))
        {
            r_out.print("ERR level <0..100>\r\n");
        }
        else
        {
/* set, stored, confirmed */
            set_level(l_value);
            g_s_prefs.putUInt("level", l_value);
            r_out.print("OK\r\n");
        }
    }
/* the volume */
    else if (strcasecmp(pc_cmd, "vol") == 0)
    {
        if ((l_value < 0) || (l_value > VOL_MAX))
        {
            r_out.print("ERR vol <0..127>\r\n");
        }
        else
        {
/* kept, sent to the speaker */
            g_ui32_volume = l_value;
            g_s_a2dp.set_volume(l_value);
/* stored, confirmed */
            g_s_prefs.putUInt("vol", l_value);
            r_out.print("OK\r\n");
        }
    }
/* the bitpool cap */
    else if (strcasecmp(pc_cmd, "bitpool") == 0)
    {
        if ((l_value < 0) || (l_value > BITPOOL_MAX) || ((l_value > 0) && (l_value < BITPOOL_MIN)))
        {
            r_out.print("ERR bitpool <2..250> or 0 (no cap)\r\n");
        }
        else
        {
/* kept, stored, confirmed */
            g_ui8_bitpool_cap = (uint8_t)l_value;
            g_s_prefs.putUChar("bitpool", (uint8_t)l_value);
            r_out.print("OK (used from the next connection)\r\n");
        }
    }
/* mute */
    else if (strcasecmp(pc_cmd, "mute") == 0)
    {
        i32_choice = two_words(pc_arg, "on", "off");
        if (i32_choice == NO_NUMBER)
        {
/* neither word */
            r_out.print("ERR mute on|off\r\n");
        }
        else
        {
/* set, confirmed */
            g_b_muted = i32_choice != 0;
            r_out.print("OK\r\n");
        }
    }
    else
    {
/* not a command */
        r_out.printf("ERR unknown command '%s' (help)\r\n", pc_cmd);
    }
}

/* one command line */
static void command(char *pc_line, Print &r_out)
{
/* local variables */
    char *pc_cmd;
    char *pc_arg;
    char *pc_end;

/* start values */
    pc_cmd = strtok(pc_line, " \t");
    pc_arg = nullptr;
    pc_end = nullptr;
/* an empty line is no command */
    if (pc_cmd != nullptr)
    {
/* the argument is the rest of the line, without spaces around it */
        pc_arg = strtok(nullptr, "");
        if (pc_arg != nullptr)
        {
/* spaces before it */
            while ((*pc_arg == ' ') || (*pc_arg == '\t'))
            {
                pc_arg++;
            }
/* spaces behind it */
            pc_end = pc_arg + strlen(pc_arg);
            while ((pc_end > pc_arg) && ((pc_end[-YES] == ' ') || (pc_end[-YES] == '\t')))
            {
/* cut off */
                pc_end--;
                *pc_end = 0;
            }
/* nothing but spaces is no argument */
            if (*pc_arg == 0)
            {
                pc_arg = nullptr;
            }
        }
/* the commands */
        if ((strcasecmp(pc_cmd, "help") == 0) || (strcmp(pc_cmd, "?") == 0))
        {
            help(r_out);
        }
        else if (strcasecmp(pc_cmd, "status") == 0)
        {
/* the Bluetooth part's status, then the loader's */
            status(r_out);
        }
        else if (strcasecmp(pc_cmd, "loader") == 0)
        {
            loader_info(r_out);
        }
/* the rate history */
        else if (strcasecmp(pc_cmd, "rates") == 0)
        {
            cmd_rates(r_out);
        }
/* the devices found */
        else if (strcasecmp(pc_cmd, "list") == 0)
        {
            list_devs(r_out);
        }
/* the menu's one-line state */
        else if (strcasecmp(pc_cmd, "info") == 0)
        {
            cmd_info(r_out);
        }
/* search */
        else if (strcasecmp(pc_cmd, "scan") == 0)
        {
            cmd_scan(r_out);
        }
/* connect */
        else if (strcasecmp(pc_cmd, "connect") == 0)
        {
            cmd_connect(pc_arg, r_out);
        }
        else if (strcasecmp(pc_cmd, "disconnect") == 0)
        {
/* a deliberate disconnect: no reconnect */
            g_b_want_connect = false;
            g_s_a2dp.disconnect();
            r_out.print("OK\r\n");
        }
/* forget the device */
        else if (strcasecmp(pc_cmd, "forget") == 0)
        {
            cmd_forget(r_out);
        }
/* the PIN */
        else if (strcasecmp(pc_cmd, "pin") == 0)
        {
            cmd_pin(pc_arg, r_out);
        }
        else
        {
/* a setting */
            cmd_setting(pc_cmd, pc_arg, r_out);
        }
    }
}

/* Line assembler per port; CR, LF or CRLF end a line, overlong lines are dropped. */
struct LineIn
{
/* the port, the line so far, its length */
    Stream &r_port;
    char ac_buf[LINE_BUF];
    int32_t i32_len;
/* the line is too long */
    bool b_overflow;

/* take what the port has */
    void poll()
    {
        int32_t i32_char;

        i32_char = 0;
/* character by character */
        while (r_port.available())
        {
            i32_char = r_port.read();
            if ((i32_char == '\r') || (i32_char == '\n'))
            {
/* the end of a line: run it, unless it was too long or is empty */
                ac_buf[i32_len] = 0;
                if (b_overflow)
                {
                    r_port.print("ERR line too long\r\n");
                }
/* a command */
                else if (i32_len != 0)
                {
                    command(ac_buf, r_port);
                }
                else
                {
/* an empty line */
                }
                i32_len = 0;
                b_overflow = false;
            }
            else if ((i32_char >= CHAR_FIRST) && (i32_char < CHAR_END))
            {
/* one more character, if there is room */
                if (i32_len < ((int32_t)sizeof ac_buf - YES))
                {
                    ac_buf[i32_len] = (char)i32_char;
                    i32_len++;
                }
                else
                {
/* no room: the line is dropped */
                    b_overflow = true;
                }
            }
            else
            {
/* other control characters are ignored */
            }
        }
    }
};

/* the two command ports */
static LineIn g_s_usb_in{ Serial, { 0 }, 0, false };
static LineIn g_s_uart_in{ Serial2, { 0 }, 0, false };

/* setup / loop */

void setup()
{
    Serial.begin(UART_BAUD);
    Serial2.begin(UART_BAUD, SERIAL_8N1, UART2_RX, UART2_TX);
/* idle-high when the FPGA is not connected */
    gpio_pullup_en((gpio_num_t)UART2_RX);
/* the stored settings */
    g_s_prefs.begin("btaudio", false);
    set_tone(g_s_prefs.getUInt("tone", DEFAULT_TONE));
    set_level(g_s_prefs.getUInt("level", DEFAULT_LEVEL));
/* shape and source */
    g_b_square_wave = g_s_prefs.getBool("square", false);
    g_b_src_i2s = g_s_prefs.getBool("i2s", true);
/* volume and bitpool cap */
    g_ui32_volume = g_s_prefs.getUInt("vol", DEFAULT_VOL);
    g_ui8_bitpool_cap = g_s_prefs.getUChar("bitpool", 0);
/* the device to connect to, and the PIN */
    strlcpy(g_ac_target, g_s_prefs.getString("target", "").c_str(), sizeof g_ac_target);
    strlcpy(g_ac_pin_fixed, g_s_prefs.getString("pin", "").c_str(), sizeof g_ac_pin_fixed);
    g_b_want_connect = g_ac_target[0] != 0;
/* the I2S input */
    i2s_start();
/* Classic BT only: the controller's BLE memory goes back to the heap; */
/* reconnect to the last peer stored in NVS */
    g_s_a2dp.set_local_name("LSpectrum");
    g_s_a2dp.set_reset_ble(true);
    g_s_a2dp.set_auto_reconnect(true);
/* where the audio comes from, the volume, start */
    g_s_a2dp.set_data_callback_in_frames(get_frames);
    g_s_a2dp.set_volume(g_ui32_volume);
    g_s_a2dp.start();
/* the loader last */
    Serial.print("\r\nLSpectrum BT audio. Type 'help'.\r\n");
    status(Serial);
    loader_begin();
}

/* Report newly found (or newly named) devices. */
static void report_devices(void)
{
/* local variables */
    Dev s_dev;
    char ac_mac[MAC_BUF];
    int32_t i32_index;

/* every device not reported yet */
    for (i32_index = 0; i32_index < g_i32_ndevs; i32_index++)
    {
        if (!g_as_devs[i32_index].b_reported)
        {
/* a copy, taken while the BT task cannot change the entry */
            portENTER_CRITICAL(&g_s_devs_mux);
            g_as_devs[i32_index].b_reported = true;
            s_dev = g_as_devs[i32_index];
/* the BT task may go on; the report */
            portEXIT_CRITICAL(&g_s_devs_mux);
            mac_str(s_dev.aui8_mac, ac_mac);
            event("found %d %s %d %s", (int)i32_index, ac_mac, (int)s_dev.i32_rssi, or_text(s_dev.ac_name, "(no name)"));
        }
    }
}

/* Volume: when a speaker connects it reports its own volume over AVRCP and the library */
/* takes it (BluetoothA2DPSource bt_av_notify_evt_handler), so the stream played at the */
/* speaker's last volume while 'vol' (F3 menu) still showed the stored one. For the first */
/* 5 s of a connection the stored volume is put back (at most every 0.5 s, the speaker */
/* answers each one); after that, changes from the speaker's own buttons are taken over, */
/* so the menu shows the volume in use. */
/* A speaker that reports no volume keeps its own one (often low): set_volume() before the */
/* connection sends nothing, and the check below sees no difference. So the stored volume is */
/* sent to the speaker once, 1.5 s after it connects (seen on hardware: low until Right in F3). */
static void volume_sync(esp_a2d_connection_state_t e_conn)
{
/* local variables */
    int32_t i32_speaker;

/* start values */
    i32_speaker = 0;
    if (e_conn != ESP_A2D_CONNECTION_STATE_CONNECTED)
    {
        g_b_vol_sent = false;
    }
/* connected long enough: the stored volume goes out once */
    else if (!g_b_vol_sent && ((millis() - g_ui32_conn_ms) >= VOL_SEND_MS))
    {
        g_b_vol_sent = true;
/* sent, and said */
        esp_avrc_ct_send_set_absolute_volume_cmd(0, g_ui32_volume);
        event("volume %u sent to the speaker", (unsigned)g_ui32_volume);
    }
    else
    {
/* sent already, or not yet time */
    }
    if (e_conn == ESP_A2D_CONNECTION_STATE_CONNECTED)
    {
        i32_speaker = g_s_a2dp.get_volume();
        if ((millis() - g_ui32_conn_ms) < VOL_RESTORE_MS)
        {
/* early: the stored volume wins */
            if ((i32_speaker != (int32_t)g_ui32_volume) && ((millis() - g_ui32_vol_ms) >= VOL_RESTORE_STEP_MS))
            {
                g_ui32_vol_ms = millis();
                g_s_a2dp.set_volume(g_ui32_volume);
/* said */
                event("volume %u restored (speaker reported %d)", (unsigned)g_ui32_volume, (int)i32_speaker);
            }
        }
        else if (i32_speaker != (int32_t)g_ui32_volume)
        {
/* later: the speaker's buttons win */
            g_ui32_volume = i32_speaker;
            event("volume %u (set on the speaker)", (unsigned)g_ui32_volume);
        }
        else
        {
/* the same volume on both sides */
        }
    }
}

/* Audio stream events, and a stream that stopped while the link stays (see kick_media) */
static void stream_watch(esp_a2d_connection_state_t e_conn)
{
/* local variables */
    bool b_silent;

    if (g_i32_audio_state != g_i32_last_audio)
    {
        g_i32_last_audio = g_i32_audio_state;
/* started or suspended */
        if (g_i32_last_audio == ESP_A2D_AUDIO_STATE_STARTED)
        {
            event("audio %s", "started");
        }
        else
        {
            event("audio %s", "suspended");
        }
    }
/* connected for 3 s, no kick for 3 s, no audio asked for 3 s: start the stream again */
    if ((e_conn == ESP_A2D_CONNECTION_STATE_CONNECTED) && ((millis() - g_ui32_conn_ms) > STREAM_SETTLE_MS) &&
        ((millis() - g_ui32_kick_ms) > KICK_MS) && ((esp_timer_get_time() - g_i64_cb_last) > SILENT_US))
    {
        g_ui32_kick_ms = millis();
/* only a started stream can be kicked */
        if (g_s_a2dp.kick_media())
        {
            event("audio stream stopped: starting it again (%u)", (unsigned)g_ui32_media_restarts);
        }
    }
/* A stream the kick cannot start again (seen 2026-11-05 after quick disconnects / reconnects from */
/* the headphones: connected, media state stays idle, no audio asked for minutes): drop the link and */
/* connect again, as the user would from F3. Only with a target (not after a deliberate disconnect). */
    b_silent = (e_conn == ESP_A2D_CONNECTION_STATE_CONNECTED) && ((millis() - g_ui32_conn_ms) > STREAM_SETTLE_MS) &&
               ((esp_timer_get_time() - g_i64_cb_last) > SILENT_US);
    if (!b_silent)
    {
        g_ui32_silent_ms = 0;
    }
/* silence begins */
    else if (g_ui32_silent_ms == 0)
    {
        g_ui32_silent_ms = millis();
    }
/* 15 s of it, and a target */
    else if (((millis() - g_ui32_silent_ms) > RELINK_MS) && g_b_want_connect)
    {
        g_ui32_silent_ms = 0;
        g_ui32_relinks++;
/* said; the link is dropped */
        event("audio stream did not start again: reconnecting (%u)", (unsigned)g_ui32_relinks);
        g_s_a2dp.disconnect();
/* search for the target as soon as the link is down */
        g_b_scan_pending = true;
    }
    else
    {
/* silent, but not long enough yet */
    }
}

/* is rate a more than 2 % off rate b? */
static bool rate_off(uint32_t ui32_a, uint32_t ui32_b)
{
/* local variables */
    bool b_off;

    b_off = ((ui32_a * RATE_SCALE) > (ui32_b * RATE_SCALE_HIGH)) || ((ui32_a * RATE_SCALE) < (ui32_b * RATE_SCALE_LOW));
    return b_off;
}

/* Link role and power mode (see BTM_GetRole above): an event when they change */
static void link_watch(esp_a2d_connection_state_t e_conn)
{
/* local variables */
    uint8_t ui8_role;
    uint8_t ui8_mode;

/* start values */
    ui8_role = LINK_NONE;
    ui8_mode = LINK_NONE;
    if (e_conn == ESP_A2D_CONNECTION_STATE_CONNECTED)
    {
/* asked from the stack */
        BTM_GetRole(*g_s_a2dp.get_last_peer_address(), &ui8_role);
        BTM_ReadPowerMode(*g_s_a2dp.get_last_peer_address(), &ui8_mode);
    }
    if ((ui8_role != g_ui8_link_role) || (ui8_mode != g_ui8_link_mode))
    {
/* a role switch on a link that stayed up is counted */
        if ((ui8_role != LINK_NONE) && (g_ui8_link_role != LINK_NONE) && (ui8_role != g_ui8_link_role))
        {
            g_ui32_role_changes++;
        }
/* kept */
        g_ui8_link_role = ui8_role;
        g_ui8_link_mode = ui8_mode;
        if (ui8_role != LINK_NONE)
        {
/* said, while there is a link */
            event("link role %s, mode %s", role_name(ui8_role), mode_name(ui8_mode));
        }
    }
}

/* one entry into the rate history */
static void rate_keep(void)
{
/* local variables */
    RateLog *ps_entry;

/* start values */
    ps_entry = &g_as_rate_log[g_ui32_rate_log_n % RATE_LOG_LEN];
    ps_entry->ui32_ms = millis();
/* the two rates */
    ps_entry->ui32_i2s_hz = g_ui32_meas_i2s_hz;
    ps_entry->ui32_a2dp_hz = g_ui32_meas_a2dp_hz;
/* the counters and the link then */
    ps_entry->ui32_ovf = g_ui32_i2s_overflows;
    ps_entry->ui32_fix = g_ui32_i2s_drops + g_ui32_i2s_dups;
    ps_entry->i8_rssi = g_i8_link_rssi;
/* bitpool, role, mode */
    ps_entry->ui8_bitpool = g_ui8_bp_max;
    ps_entry->ui8_role = g_ui8_link_role;
    ps_entry->ui8_mode = g_ui8_link_mode;
/* one more entry */
    g_ui32_rate_log_n++;
}

/* Rate check (see the audio source's notes): both rates every 2 s, kept in the history */
static void rate_check(esp_a2d_connection_state_t e_conn)
{
/* local variables */
    int64_t i64_now;
    uint32_t ui32_gross;
    uint32_t ui32_req;
/* packets and frames so far */
    uint32_t ui32_packets;
    uint32_t ui32_frames;
/* the period in seconds; a stream is running */
    double d_seconds;
    bool b_streaming;

/* start values */
    i64_now = esp_timer_get_time();
    ui32_gross = 0;
    ui32_req = 0;
/* nothing counted yet */
    ui32_packets = 0;
    ui32_frames = 0;
    d_seconds = 0;
/* every 2 s */
    b_streaming = false;
    if ((i64_now - g_i64_rate_t) >= RATE_PERIOD_US)
    {
/* frames received and frames asked for, so far */
        ui32_gross = g_ui32_i2s_gross;
        ui32_req = g_ui32_a2dp_req;
/* media packets and SBC frames per second */
        if (g_i64_rate_t != 0)
        {
            ui32_packets = g_ui32_pk_n;
            ui32_frames = g_ui32_pk_frames;
/* per second, rounded */
            g_ui32_meas_pk_hz = (uint32_t)((((ui32_packets - g_ui32_pk_n0) * US_PER_S) / (i64_now - g_i64_rate_t)) + ROUND_HALF);
            g_ui32_meas_pkfr_hz = (uint32_t)((((ui32_frames - g_ui32_pk_f0) * US_PER_S) / (i64_now - g_i64_rate_t)) + ROUND_HALF);
/* the counts of this period's end */
            g_ui32_pk_n0 = ui32_packets;
            g_ui32_pk_f0 = ui32_frames;
        }
/* the signal strength every 10 s */
        if (e_conn == ESP_A2D_CONNECTION_STATE_CONNECTED)
        {
            if ((g_ui32_rssi_n % RSSI_EVERY) == 0)
            {
                esp_bt_gap_read_rssi_delta(*g_s_a2dp.get_last_peer_address());
            }
/* counted; role and mode */
            g_ui32_rssi_n++;
        }
        link_watch(e_conn);
/* the two sample rates */
        if (g_i64_rate_t != 0)
        {
            d_seconds = (i64_now - g_i64_rate_t) / US_PER_S;
/* frames per second, rounded */
            g_ui32_meas_i2s_hz = (uint32_t)(((ui32_gross - g_ui32_rate_g0) / d_seconds) + ROUND_HALF);
            g_ui32_meas_a2dp_hz = (uint32_t)(((ui32_req - g_ui32_rate_q0) / d_seconds) + ROUND_HALF);
/* a stream runs: connected, audio asked for lately, a rate measured */
            b_streaming = (e_conn == ESP_A2D_CONNECTION_STATE_CONNECTED) && ((i64_now - g_i64_cb_last) < STREAMING_US) &&
                          (g_ui32_meas_a2dp_hz > 0);
            if (!b_streaming)
            {
                g_ui32_rate_first = 0;
            }
/* a measurement worth keeping */
            else if ((g_ui32_rate_first < RATE_FIRST_KEPT) || rate_off(g_ui32_meas_i2s_hz, g_ui32_kept_i2s) ||
                     rate_off(g_ui32_meas_a2dp_hz, g_ui32_kept_a2dp))
            {
/* the first measurements of a stream, and every one that differs from the last kept */
                if (g_ui32_rate_first >= RATE_FIRST_KEPT)
                {
                    event("audio rates changed: i2s %u Hz, a2dp %u Hz", (unsigned)g_ui32_meas_i2s_hz,
                          (unsigned)g_ui32_meas_a2dp_hz);
                }
/* kept */
                g_ui32_rate_first++;
                g_ui32_kept_i2s = g_ui32_meas_i2s_hz;
                g_ui32_kept_a2dp = g_ui32_meas_a2dp_hz;
/* into the history */
                rate_keep();
            }
            else
            {
/* streaming at the rates kept */
            }
        }
        g_i64_rate_t = i64_now;
        g_ui32_rate_g0 = ui32_gross;
        g_ui32_rate_q0 = ui32_req;
    }
}

/* the main loop: the loader, the command ports, then the Bluetooth link's state */
void loop()
{
    char ac_mac[MAC_BUF];
    esp_a2d_connection_state_t e_conn;
/* a search is running; the loader's link and its watchdog */
    bool b_disc;

    loader_poll();
    loader_check();
/* commands from USB and from the FPGA */
    g_s_usb_in.poll();
    g_s_uart_in.poll();
    report_devices();
/* Report connection / discovery changes. */
    e_conn = g_s_a2dp.get_connection_state();
    if (e_conn != g_e_last_conn)
    {
        g_e_last_conn = e_conn;
/* since when; said with the device's address and name */
        g_ui32_conn_ms = millis();
        mac_str(*g_s_a2dp.get_last_peer_address(), ac_mac);
        event("%s %s %s", conn_name(e_conn), ac_mac, g_ac_peer_name);
    }
/* volume, the stream, the rates */
    volume_sync(e_conn);
    stream_watch(e_conn);
    rate_check(e_conn);
/* the codec set up, and the IDF fix used */
    if (g_ui32_cfg_events != g_ui32_last_cfg)
    {
        g_ui32_last_cfg = g_ui32_cfg_events;
        event("audio codec: SBC %u Hz (0x%02x)", (unsigned)sbc_hz(g_ui8_sbc_cfg), (unsigned)g_ui8_sbc_cfg);
    }
/* the IDF fix */
    if (g_ui32_codec_forced != g_ui32_last_forced)
    {
        g_ui32_last_forced = g_ui32_codec_forced;
        event("codec set up by the IDF fix (%u)", (unsigned)g_ui32_last_forced);
    }
/* the search started or ended */
    b_disc = g_s_a2dp.is_discovery_active();
    if (b_disc != g_b_last_disc)
    {
/* said */
        g_b_last_disc = b_disc;
        event("discovery %s", on_off(b_disc));
    }
/* a scan asked for while a link was up */
    if (g_b_scan_pending && (e_conn == ESP_A2D_CONNECTION_STATE_DISCONNECTED))
    {
        g_b_scan_pending = false;
        start_discovery();
    }
/* The library stops searching after a deliberate disconnect and gives up after */
/* its reconnect retries; restart discovery if we still have a target to reach. */
/* The first 15 s belong to the library's own start-up (10 s wait + reconnect). */
    if (g_b_want_connect && (e_conn == ESP_A2D_CONNECTION_STATE_DISCONNECTED) && !b_disc && (millis() > STARTUP_MS) &&
        ((millis() - g_ui32_last_kick) > DISCOVERY_RETRY_MS))
    {
        start_discovery();
    }
    delay(LOOP_DELAY_MS);
}
