#!/usr/bin/env python3
"""Synthesize the kit's default alert ring from scratch (no sampled audio).

An electronic two-tone warble in the spirit of late-90s handset trills —
an original approximation, not a recording or recreation of any specific
ringtone. Writes WAV; install.sh / the repo build converts to AIFF via
afconvert. Regenerate with:  python3 tools/generate-ring.py <outdir>
"""
import math
import struct
import sys
import wave

RATE = 44100


def warble(dur, f_lo=852.0, f_hi=1477.0, alt_hz=16.0, amp=0.62):
    """Alternate two tones alt_hz times/sec with a soft envelope."""
    n = int(dur * RATE)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / RATE
        f = f_hi if int(t * alt_hz * 2) % 2 else f_lo
        phase += 2 * math.pi * f / RATE
        # square-ish: sine + a third harmonic for an electronic edge
        s = math.sin(phase) + 0.28 * math.sin(3 * phase)
        env = min(1.0, t / 0.012) * min(1.0, (dur - t) / 0.05)
        out.append(s * env * amp / 1.28)
    return out


def silence(dur):
    return [0.0] * int(dur * RATE)


def write(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(
            struct.pack("<h", max(-32767, min(32767, int(s * 32767))))
            for s in samples))
    print("wrote", path)


outdir = sys.argv[1] if len(sys.argv) > 1 else "."
# short: one burst — the system alert
write(f"{outdir}/MatrixRing.wav", warble(0.85))
# long: ring-ring pause ring-ring — the notification hook
burst = warble(0.55) + silence(0.18) + warble(0.55)
write(f"{outdir}/MatrixRingLong.wav", burst + silence(0.7) + burst)
