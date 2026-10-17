#!/usr/bin/env python3
"""
Pre-renders the demo-mode narration with Piper, an open-source offline TTS engine,
so demo mode works with no API keys. This is NOT ElevenLabs and is labelled as a
demo voice in the app.

    npx tsx scripts/export-demo-texts.ts > /tmp/demo-texts.json
    python3 scripts/render-demo-voice.py /tmp/demo-texts.json <libritts-high.onnx> assets/demo/voice

Voice model: Piper "en_US-libritts-high" (trained on LibriTTS, CC BY 4.0).
"""
import hashlib
import io
import json
import subprocess
import sys
import wave
from pathlib import Path

from piper import PiperVoice, SynthesisConfig

VOICES = [
    {"id": "demo-wren", "name": "Wren (demo voice)", "speaker": 133,
     "description": "Soft, unhurried. Offline sample voice, not ElevenLabs"},
    {"id": "demo-rowan", "name": "Rowan (demo voice)", "speaker": 209,
     "description": "Low and steady. Offline sample voice, not ElevenLabs"},
]


def clip_name(text):
    return hashlib.sha1(text.strip().encode()).hexdigest()[:16] + ".m4a"


def render(voice, speaker, text, out):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        voice.synthesize_wav(text, w, syn_config=SynthesisConfig(speaker_id=speaker, length_scale=1.18, noise_scale=0.6, noise_w_scale=0.7))
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", "-", "-af", "highpass=f=70",
         "-ac", "1", "-ar", "44100", "-c:a", "aac", "-b:a", "56k", str(out)],
        input=buf.getvalue(), check=True,
    )


def main(texts_file, model, out_dir):
    data = json.loads(Path(texts_file).read_text())
    voice = PiperVoice.load(model)
    out = Path(out_dir)
    for v in VOICES:
        d = out / v["id"]
        d.mkdir(parents=True, exist_ok=True)
        render(voice, v["speaker"], data["preview"], d / "preview.m4a")
        for line in data["lines"]:
            target = d / clip_name(line)
            if not target.exists():
                render(voice, v["speaker"], line, target)
        print(v["id"], len(data["lines"]), "lines")
    manifest = {
        "engine": "Piper (offline, open source) with the en_US-libritts-high model",
        "license": "Piper is MIT licensed; the LibriTTS-based voice model is CC BY 4.0.",
        "voices": [{"id": v["id"], "name": v["name"], "description": v["description"]} for v in VOICES],
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main(*sys.argv[1:4])
