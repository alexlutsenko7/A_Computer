#!/usr/bin/env python3
"""mk_nestables.py -- LNES: the lookup tables of the sound mixer and the colour palette.

    python3 tools/mk_nestables.py            (in LNES/ep4_ce15)

writes rtl/nes_pulse.hex   32 entries: output of the two pulse channels by the sum of their levels
       rtl/nes_tnd.hex     256 entries: triangle, noise and sample channel by 3 * t + 2 * n + d
       rtl/nes_palette.hex 512 entries of 12 bits (red, green, blue: 4 bits each), index = emphasis * 64 + colour
and    ../../ESP32/v1|v2/src/nes_palette.h   the 64 colours without emphasis, 8 bits per channel (screenshots)

The mixer formulas and the composite video levels are the ones published in the NESdev documentation; the PPU
has no RGB output, so the palette is the decoded NTSC signal of each colour.
"""
import math
import os

# full scale of the 10-bit sound output
AUDIO_MAX = 1023
# entries of the two mixer tables (the next power of two above 31 and 203)
PULSE_ENTRIES = 32
TND_ENTRIES = 256
PULSE_LAST = 30
TND_LAST = 202
# colours and emphasis combinations
COLOURS = 64
EMPHASES = 8
# samples of one colour carrier period
PHASES = 12
HALF = 6
# composite levels (volts): low and high of the four brightness steps, black and white
LOW = (0.350, 0.518, 0.962, 1.550)
HIGH = (1.094, 1.506, 1.962, 1.962)
BLACK = 0.518
WHITE = 1.962
# an emphasis bit darkens its part of the carrier period by this factor
ATTENUATION = 0.746
# hue numbers: 0 = no carrier at the high level, 13 = at the low level, 14 and 15 = black
HUE_GREY_LOW = 13
HUE_BLACK = 14
# carrier phase of emphasis red, green, blue (in hue numbers)
EMPH_HUE = (12, 4, 8)
# decoder: phase offset of the colour axes (samples) and the saturation
AXIS_OFFSET = -0.1
SATURATION = 1.4
# highest value of a 4-bit and of an 8-bit channel
MAX4 = 15
MAX8 = 255
# entries per line of the C header
PER_LINE = 8


def wave(phase, hue):
    """is the carrier of this hue high in this sample?"""
    return (hue + phase + 8) % PHASES < HALF


def colour_rgb(colour, emphasis):
    """one palette entry -> (r, g, b), each 0.0 .. 1.0"""
    level = colour >> 4
    hue = colour & 15
    # the two voltages the signal switches between
    low = LOW[level]
    high = HIGH[level]
    if hue == 0:
        low = high
    if hue == HUE_GREY_LOW:
        high = low
    if hue >= HUE_BLACK:
        low = high = BLACK
    y = i = q = 0.0
    for phase in range(PHASES):
        volt = high if wave(phase, hue) else low
        # emphasis darkens a part of the period
        for bit in range(3):
            if (emphasis >> bit) & 1 and wave(phase, EMPH_HUE[bit]):
                volt = BLACK + (volt - BLACK) * ATTENUATION
        value = (volt - BLACK) / (WHITE - BLACK)
        # the decoder's sum over one carrier period
        angle = math.pi * (phase + AXIS_OFFSET) / HALF
        y += value / PHASES
        i += value * math.cos(angle) / PHASES
        q += value * math.sin(angle) / PHASES
    i *= SATURATION
    q *= SATURATION
    # YIQ -> RGB
    r = y + 0.956 * i + 0.621 * q
    g = y - 0.272 * i - 0.647 * q
    b = y - 1.106 * i + 1.703 * q
    return tuple(min(1.0, max(0.0, c)) for c in (r, g, b))


def main():
    # the sound tables
    pulse = [0] * PULSE_ENTRIES
    for n in range(1, PULSE_LAST + 1):
        pulse[n] = round(AUDIO_MAX * 95.52 / (8128.0 / n + 100))
    tnd = [0] * TND_ENTRIES
    for n in range(1, TND_LAST + 1):
        tnd[n] = round(AUDIO_MAX * 163.67 / (24329.0 / n + 100))
    # the sum of both must fit the output
    assert pulse[PULSE_LAST] + tnd[TND_LAST] <= AUDIO_MAX
    with open('rtl/nes_pulse.hex', 'w', newline='\n') as f:
        f.write(''.join('%03X\n' % v for v in pulse))
    with open('rtl/nes_tnd.hex', 'w', newline='\n') as f:
        f.write(''.join('%03X\n' % v for v in tnd))
    # the palette for the FPGA
    with open('rtl/nes_palette.hex', 'w', newline='\n') as f:
        for emphasis in range(EMPHASES):
            for colour in range(COLOURS):
                r, g, b = (round(c * MAX4) for c in colour_rgb(colour, emphasis))
                f.write('%X%X%X\n' % (r, g, b))
    # the palette for the ESP32's screenshots
    rows = []
    for colour in range(COLOURS):
        r, g, b = (round(c * MAX8) for c in colour_rgb(colour, 0))
        rows.append('0x%02X%02X%02Xu' % (r, g, b))
    text = '/* nes_palette.h -- the NES colours as 0xRRGGBB (made by LNES/ep4_ce15/tools/mk_nestables.py) */\n'
    text += '#ifndef NES_PALETTE_H\n#define NES_PALETTE_H\n\n#include <stdint.h>\n\n'
    text += '/* colours of the NES */\n#define NES_COLOURS %d\n\n' % COLOURS
    text += 'static const uint32_t g_aui32_nes_palette[NES_COLOURS] =\n{\n'
    for a in range(0, COLOURS, PER_LINE):
        text += '    ' + ', '.join(rows[a:a + PER_LINE]) + (',\n' if a + PER_LINE < COLOURS else '\n')
    text += '};\n\n#endif\n'
    for version in ('v1', 'v2'):
        path = '../../ESP32/%s/src/nes_palette.h' % version
        if os.path.isdir(os.path.dirname(path)):
            open(path, 'w', newline='\n').write(text)
    # a few colours to look at: red, blue, green, sky blue, white
    for colour in (0x16, 0x12, 0x1A, 0x22, 0x30, 0x0F, 0x27):
        print('%02X' % colour, '%02X%02X%02X' % tuple(round(c * MAX8) for c in colour_rgb(colour, 0)))


main()
