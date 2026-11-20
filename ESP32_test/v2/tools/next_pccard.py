#!/usr/bin/env python3
"""next_pccard.py PORT IMAGE [LOG [JOURNAL]] -- the PC side of the firmware's test option NEXT_SERIAL_CARD.

LNext (the Spectrum Next) then takes its SD card's sectors from the disk image IMAGE on the PC instead of the
real card (ESP32/v2/src/pccard.h). The image is opened read only: sectors the machine writes are kept in memory
and given back when it reads them again. With a JOURNAL file they are also appended to it ("<sector> <hex>" per
line) and taken from it at the next start, so the machine's changes stay; without one they are lost when this
program ends. Everything else the ESP32 prints goes to LOG (default: the screen). Needs pyserial; runs until
it is stopped.

    python next_pccard.py COM12 boot.vhd next_card.log next_card.journal
"""
import re
import sys
import time
import serial

# the serial port's speed, a sector's bytes, the byte that starts an answer
BAUD = 921600
SECTOR = 512
MARK = b"\xA5"
# seconds between two lines of statistics
REPORT_S = 5.0
# a request at the end of a line (another task's text may stand before it): R or W, the sector, a written
# sector's hex digits
REQUEST = re.compile(rb"#([RW])(\d+)(?: ([0-9A-F]*))?$")


def main():
    port_name = sys.argv[1]
    image = open(sys.argv[2], "rb")
    # names of Bluetooth devices may hold any bytes
    log = open(sys.argv[3], "w", buffering=1, encoding="latin-1", errors="replace") if len(sys.argv) > 3 else sys.stdout
    written = {}
    journal = None
    if len(sys.argv) > 4:
        # the sectors written in earlier runs
        try:
            for entry in open(sys.argv[4]):
                number, digits = entry.split()
                written[int(number)] = bytes.fromhex(digits)
        except FileNotFoundError:
            pass
        journal = open(sys.argv[4], "a", buffering=1)
    reads = 0
    writes = 0
    last_report = time.time()
    start = time.time()
    # open the port without pulsing the ESP32's reset lines
    port = serial.Serial()
    port.port = port_name
    port.baudrate = BAUD
    port.timeout = 0.2
    port.dtr = False
    port.rts = False
    port.open()
    line = b""
    while True:
        # what is there, or wait for one byte
        data = port.read(port.in_waiting or 1)
        if data:
            line += data
        while b"\n" in line:
            text, line = line.split(b"\n", 1)
            text = text.strip()
            request = REQUEST.search(text)
            if request and request.group(1) == b"R":
                # a sector is wanted
                lba = int(request.group(2))
                if lba in written:
                    sector = written[lba]
                else:
                    image.seek(lba * SECTOR)
                    sector = image.read(SECTOR).ljust(SECTOR, b"\0")
                port.write(MARK + sector)
                reads += 1
                log.write("read %d at %.3f\n" % (lba, time.time() - start))
            elif request and len(request.group(3)) == 2 * SECTOR:
                # a sector was written
                lba = int(request.group(2))
                written[lba] = bytes.fromhex(request.group(3).decode("ascii"))
                if journal:
                    journal.write("%d %s\n" % (lba, request.group(3).decode("ascii")))
                port.write(MARK)
                writes += 1
                log.write("write %d\n" % lba)
            elif text:
                log.write(text.decode("ascii", "replace") + "\n")
        if time.time() - last_report > REPORT_S:
            last_report = time.time()
            log.write("-- %d sectors read, %d written (%d kept)\n" % (reads, writes, len(written)))


main()
