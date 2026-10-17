#!/usr/bin/env python3
"""
Synthesises Present's built-in ambient music from scratch (no samples), so the
tracks are original works released under CC0. Requires numpy, scipy and ffmpeg.

    python3 scripts/generate-ambient.py assets/music

Writes <slug>.m4a files plus manifest.json (with measured loudness) into the
output directory. Deterministic: the same seed produces the same audio.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
from scipy.signal import fftconvolve, butter, sosfilt

SR = 44100


def midi_hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def envelope(n, attack, release):
    env = np.ones(n)
    a = min(int(attack * SR), n // 2)
    r = min(int(release * SR), n // 2)
    if a:
        env[:a] = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
    if r:
        env[-r:] = 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, r))
    return env


def pad_note(freq, dur, rng, brightness=1.6, harmonics=6, detune_cents=4.0):
    """A soft, slowly breathing pad tone in stereo."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    for side, sign in ((0, -1), (1, 1)):
        for k in range(3):
            cents = sign * detune_cents * (k - 1) + rng.uniform(-1.5, 1.5)
            f = freq * 2 ** (cents / 1200)
            phase = rng.uniform(0, 2 * np.pi)
            for h in range(1, harmonics + 1):
                amp = 1.0 / h ** brightness
                out[:, side] += amp * np.sin(2 * np.pi * f * h * t + phase * h)
    lfo = 0.85 + 0.15 * np.sin(2 * np.pi * rng.uniform(0.04, 0.09) * t + rng.uniform(0, 6.28))
    out *= lfo[:, None]
    return out / 6.0


def bell(freq, rng, dur=6.0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    tone = (
        np.sin(2 * np.pi * freq * t)
        + 0.35 * np.sin(2 * np.pi * freq * 2.01 * t)
        + 0.12 * np.sin(2 * np.pi * freq * 3.98 * t) * np.exp(-t * 2.5)
    )
    env = np.exp(-t * rng.uniform(0.7, 1.0)) * envelope(n, 0.02, 1.0)
    pan = rng.uniform(0.3, 0.7)
    mono = tone * env
    return np.stack([mono * (1 - pan), mono * pan], axis=1)


def soft_pluck(freq, rng, dur=5.0):
    """A felt-piano-like note: additive partials with faster decay on the upper ones."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    mono = np.zeros(n)
    for h, a in zip(range(1, 7), (1.0, 0.45, 0.22, 0.12, 0.06, 0.03)):
        mono += a * np.sin(2 * np.pi * freq * h * (1 + 0.0004 * h) * t) * np.exp(-t * (0.9 + 0.7 * h))
    mono *= envelope(n, 0.008, 0.8)
    pan = rng.uniform(0.35, 0.65)
    return np.stack([mono * (1 - pan), mono * pan], axis=1)


def place(buf, sig, start):
    s = int(start * SR)
    e = min(len(buf), s + len(sig))
    if e > s:
        buf[s:e] += sig[: e - s]


def lowpass(x, cutoff, order=2):
    sos = butter(order, cutoff, btype="low", fs=SR, output="sos")
    return sosfilt(sos, x, axis=0)


def highpass(x, cutoff, order=2):
    sos = butter(order, cutoff, btype="high", fs=SR, output="sos")
    return sosfilt(sos, x, axis=0)


def reverb(x, rng, seconds=4.5, mix=0.45):
    n = int(seconds * SR)
    t = np.arange(n) / SR
    ir = np.zeros((n, 2))
    for ch in range(2):
        noise = rng.standard_normal(n) * np.exp(-t * (6.9 / seconds))
        ir[:, ch] = lowpass(noise, 5000)
    ir /= np.sqrt((ir ** 2).sum(axis=0, keepdims=True))
    wet = np.stack([fftconvolve(x[:, ch], ir[:, ch])[: len(x)] for ch in range(2)], axis=1)
    return (1 - mix) * x + mix * wet * 0.9


def air(n, rng, level=0.01):
    noise = rng.standard_normal((n, 2))
    noise = lowpass(highpass(noise, 2500), 7000)
    t = np.arange(n) / SR
    swell = 0.6 + 0.4 * np.sin(2 * np.pi * 0.05 * t)[:, None]
    return noise * level * swell


def chord_bed(chords, chord_len, total, rng, overlap=7.0, octave_shift=0, **pad_kw):
    n = int(total * SR)
    buf = np.zeros((n, 2))
    start = 0.0
    i = 0
    while start < total:
        notes = chords[i % len(chords)]
        dur = chord_len + overlap
        for m in notes:
            note = pad_note(midi_hz(m + octave_shift), dur, rng, **pad_kw)
            note *= envelope(len(note), overlap, overlap)[:, None]
            place(buf, note * (0.9 if m < 55 else 0.6), start)
        start += chord_len
        i += 1
    return buf


def linen(total, rng):
    # D major colours: Dmaj9, Bm11, Gmaj9, Asus2
    chords = [[50, 57, 61, 64, 66], [47, 54, 57, 62, 64], [43, 50, 57, 59, 62], [45, 52, 57, 59, 64]]
    buf = chord_bed(chords, 16.0, total, rng, brightness=1.8, harmonics=5)
    pent = [74, 76, 78, 81, 83, 86]
    t = rng.uniform(4, 8)
    while t < total - 6:
        place(buf, bell(midi_hz(rng.choice(pent)), rng) * 0.08, t)
        t += rng.uniform(7, 14)
    buf = lowpass(buf, 3200)
    buf += air(len(buf), rng, 0.006)
    return reverb(buf, rng, 5.0, 0.5)


def low_tide(total, rng):
    # Low, slowly beating drones with wave-like filtered noise. For sleep.
    n = int(total * SR)
    t = np.arange(n) / SR
    buf = np.zeros((n, 2))
    for m, lvl in ((33, 1.0), (40, 0.6), (45, 0.5), (52, 0.18)):
        tone = pad_note(midi_hz(m), total, rng, brightness=2.4, harmonics=4, detune_cents=2.5)
        buf += tone * lvl
    noise = lowpass(rng.standard_normal((n, 2)), 600)
    waves = np.zeros(n)
    pos = 0.0
    while pos < total:
        length = rng.uniform(8, 13)
        seg = int(length * SR)
        s = int(pos * SR)
        e = min(n, s + seg)
        waves[s:e] += np.sin(np.linspace(0, np.pi, seg))[: e - s] ** 2
        pos += length * rng.uniform(0.75, 0.95)
    buf += noise * waves[:, None] * 0.12
    buf = lowpass(buf, 1400)
    return reverb(buf, rng, 6.0, 0.55)


def morning_field(total, rng):
    # Light pad (Cmaj7, Am9, Fmaj9, G6) with unhurried felt-piano notes.
    chords = [[48, 55, 59, 64], [45, 52, 59, 60, 64], [41, 48, 55, 57, 64], [43, 50, 55, 59, 64]]
    buf = chord_bed(chords, 14.0, total, rng, brightness=1.9, harmonics=5) * 0.75
    scale = [60, 62, 64, 67, 69, 72, 74, 76]
    t = rng.uniform(2, 4)
    while t < total - 5:
        # Short, gentle phrases of 2-4 notes, then space.
        for _ in range(rng.integers(2, 5)):
            place(buf, soft_pluck(midi_hz(rng.choice(scale)), rng) * 0.11, t)
            t += rng.uniform(0.9, 1.8)
        t += rng.uniform(5, 10)
    buf = lowpass(buf, 4200)
    buf += air(len(buf), rng, 0.004)
    return reverb(buf, rng, 4.0, 0.42)


TRACKS = [
    ("linen", "Linen", "calm", linen, 1),
    ("low-tide", "Low Tide", "sleep", low_tide, 2),
    ("morning-field", "Morning Field", "bright", morning_field, 3),
]


def loudness(path):
    res = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af", "ebur128=framelog=quiet", "-f", "null", "-"],
        capture_output=True, text=True, check=True,
    )
    summary = res.stderr[res.stderr.rfind("Summary:"):]
    return float(re.search(r"I:\s+(-?[\d.]+) LUFS", summary).group(1))


def main(out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    total = 180.0
    manifest = {"tracks": []}
    for slug, title, mood, fn, seed in TRACKS:
        rng = np.random.default_rng(seed)
        audio = fn(total, rng)
        # Fade the very ends slightly so loops never click, then peak-normalise to -3 dBFS.
        audio *= envelope(len(audio), 0.5, 0.5)[:, None]
        audio /= np.abs(audio).max() / 10 ** (-3 / 20)
        pcm = (audio * 32767).astype("<i2").tobytes()
        m4a = out / f"{slug}.m4a"
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "s16le", "-ar", str(SR), "-ac", "2", "-i", "-",
             "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", str(m4a)],
            input=pcm, check=True,
        )
        lufs = loudness(m4a)
        manifest["tracks"].append({
            "slug": slug, "title": title, "file": m4a.name, "durationSeconds": total,
            "loudnessLufs": round(lufs, 2), "mood": mood,
            "license": "Original ambient music made for Present. CC0 (public domain).",
        })
        print(f"{title}: {lufs:.1f} LUFS")
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "assets/music")
