#!/usr/bin/env python3
"""Real-time test stream for decodium-rx -s stdin.

Writes raw 12 kHz s16le audio to stdout at real-time pace: low noise, and
at every UTC slot boundary the given test slot (a WAV file of one slot).
Used to check slot alignment end to end; not shipped.

    stream-test.py SLOT.wav PERIOD SECONDS | decodium-rx -m ft8 -s stdin
"""

import array
import random
import sys
import time
import wave

RATE = 12000
CHUNK = 1200


def main():
    path, period, seconds = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    with wave.open(path, "rb") as src:
        slot = array.array("h", src.readframes(src.getnframes()))
    rng = random.Random(1)
    out = sys.stdout.buffer
    start = time.time()
    t = start
    sent = 0
    while t - start < seconds:
        chunk = array.array("h")
        for i in range(CHUNK):
            ts = start + (sent + i) / RATE
            pos = int(round((ts % period) * RATE))
            value = slot[pos] if pos < len(slot) else int(rng.gauss(0, 300))
            chunk.append(value)
        out.write(chunk.tobytes())
        out.flush()
        sent += CHUNK
        t = start + sent / RATE
        delay = t - time.time()
        if delay > 0:
            time.sleep(delay)


if __name__ == "__main__":
    main()
