#!/usr/bin/env python3
"""Generates the two alert sounds, so they are ours and there is nothing to
download, install or attribute. Run it to regenerate them:

    python3 sounds/make-sounds.py

Deliberately NOT an imitation of Japan's broadcast early-warning chime, which
is a copyrighted composition.

The unease is built from four things rather than volume:

  * two tones detuned a few hertz apart, which beat against each other in a
    slow wobble;
  * intervals pulled about forty cents off equal temperament, so they land
    between the notes and never quite resolve;
  * a pitch that sags as the sound decays, which reads as something going
    wrong rather than something being announced;
  * and the whole thing reversed. A note played backwards swells out of
    nothing and then stops dead, which is the opposite of how any real object
    sounds, and the ear finds it unsettling for exactly that reason.
"""

# Forty cents sharp: far enough to be audibly wrong, close enough that it
# reads as out of tune rather than as a different note.
OFFKEY = 2 ** (40 / 1200)

import math
import struct
import wave

RATE = 22050


def voice(f_start, f_end, ms, volume=0.4, detune=3.0,
          vibrato_hz=5.0, vibrato_depth=0.004,
          attack_ms=12, release_ms=180):
    """One note as a pair of slightly mistuned oscillators, gliding from one
    pitch to another. The mistuning is the point: two sines a few hertz apart
    cancel and reinforce in a slow pulse the ear reads as unsteady."""
    n = int(RATE * ms / 1000)
    attack = max(1, int(RATE * attack_ms / 1000))
    release = max(1, int(RATE * release_ms / 1000))
    out = []
    phase1 = phase2 = 0.0
    for i in range(n):
        t = i / RATE
        progress = i / max(1, n - 1)
        base = f_start + (f_end - f_start) * progress
        wobble = 1.0 + vibrato_depth * math.sin(2 * math.pi * vibrato_hz * t)
        phase1 += 2 * math.pi * base * wobble / RATE
        phase2 += 2 * math.pi * (base + detune) * wobble / RATE

        env = 1.0
        if i < attack:
            env = i / attack
        elif i > n - release:
            env = max(0.0, (n - i) / release) ** 1.5

        out.append(volume * env * 0.5 * (math.sin(phase1) + math.sin(phase2)))
    return out


def silence(ms):
    return [0.0] * int(RATE * ms / 1000)


def blend(a, b):
    """Two notes sounding together."""
    n = max(len(a), len(b))
    a = a + [0.0] * (n - len(a))
    b = b + [0.0] * (n - len(b))
    return [a[i] + b[i] for i in range(n)]


def chain(*parts):
    return [s for p in parts for s in p]


def echo(samples, delay_ms=170, decay=0.33, repeats=2):
    """A little room, so the sound has somewhere to fall away into."""
    delay = int(RATE * delay_ms / 1000)
    out = list(samples) + [0.0] * delay * repeats
    for r in range(1, repeats + 1):
        gain = decay ** r
        offset = delay * r
        for i, s in enumerate(samples):
            out[i + offset] += s * gain
    return out


def reverse(samples):
    return samples[::-1]


def write(path, samples):
    peak = max(1e-9, max(abs(s) for s in samples))
    gain = min(1.0, 0.85 / peak)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s * gain)) * 32767))
            for s in samples))
    print(path, "%.2fs" % (len(samples) / RATE))


# A confirmed report. A minor third, hollow rather than cheerful, sagging very
# slightly as it fades. Enough to make you look up; not enough to alarm you.
report = chain(
    voice(659.3, 654.0, 240, volume=0.34, release_ms=140),          # E5, drifting down
    silence(40),
    blend(
        voice(784.0, 770.0, 620, volume=0.30, release_ms=380),      # G5
        voice(987.8 * OFFKEY, 966.0 * OFFKEY, 620, volume=0.16, release_ms=380, detune=2.0),
    ),
)
write("sounds/report.wav", reverse(echo(report, delay_ms=200, decay=0.28, repeats=2)))

# An early warning. A tritone — 739.99 against 1046.5 — held, wavering, then
# falling. Twice, because once can be mistaken for something else.
def pang():
    return blend(
        voice(740.0, 700.0, 300, volume=0.34, detune=4.0,
              vibrato_hz=8.5, vibrato_depth=0.007, release_ms=130),
        voice(1046.5 * OFFKEY, 990.0 * OFFKEY, 300, volume=0.28, detune=3.0,
              vibrato_hz=8.5, vibrato_depth=0.007, release_ms=130),
    )

warning = chain(pang(), silence(45), pang(),
                blend(
                    voice(740.0, 610.0, 420, volume=0.30, detune=5.0,
                          vibrato_hz=7.0, vibrato_depth=0.009, release_ms=290),
                    voice(1046.5 * OFFKEY, 870.0 * OFFKEY, 420, volume=0.22, detune=4.0,
                          vibrato_hz=7.0, vibrato_depth=0.009, release_ms=290),
                ))
write("sounds/warning.wav", reverse(echo(warning, delay_ms=140, decay=0.30, repeats=2)))
