"""In-person meeting fixture: four voices through ONE far-field laptop mic.

Each speaker gets a different distance (gain), the whole mix gets room
reverb and background noise. Writes room-mic.wav plus room-truth.tsv
(start, end, speaker, text). Run: python3 -I make_room_fixture.py
"""
import os, subprocess, wave
import numpy as np

RATE = 16000
VOICES = {"A": ("Samantha", 0.9), "B": ("Daniel", 0.55), "C": ("Reed (英语（美国）)", 0.7), "D": ("Flo (英语（美国）)", 0.45)}
SCRIPT = [
    ("A", "Okay, let's get started. The goal today is to agree on the onboarding metrics for the next quarter."),
    ("B", "Before we do that, I want to flag that the activation numbers from last month look off."),
    ("A", "Off in what way?"),
    ("B", "The dashboard counts trial accounts twice, so activation looks about ten percent higher than it really is."),
    ("C", "I can confirm that. I traced it yesterday. The join in the staging model duplicates rows when an account upgrades."),
    ("D", "Yeah."),
    ("D", "So should we pause the weekly report until it's fixed? Finance is reading it every Monday."),
    ("C", "I would rather ship the fix this week and add a note to the report in the meantime."),
    ("A", "That works for me. Let's add the note today and review the fix on Thursday."),
    ("B", "I'll write the note and send it to finance after this meeting."),
    ("D", "Great, and I will update the onboarding metric definitions in the doc."),
    ("A", "Perfect. Thanks everyone, that's all for today."),
]

def tts(voice, text, path):
    subprocess.run(["say", "-v", voice, "--data-format=LEI16@16000", "-o", path, text], check=True)
    with wave.open(path) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768

rng = np.random.default_rng(7)
os.makedirs("room-parts", exist_ok=True)
clips, truth, t = [], [], 0.8
for i, (spk, text) in enumerate(SCRIPT):
    voice, gain = VOICES[spk]
    audio = tts(voice, text, f"room-parts/{i}.wav") * gain
    clips.append((t, audio))
    truth.append((t, t + len(audio) / RATE, spk, text))
    t += len(audio) / RATE + rng.uniform(0.25, 0.8)
total = int((t + 1.0) * RATE)
mix = np.zeros(total, dtype=np.float32)
for start, audio in clips:
    s = int(start * RATE)
    mix[s:s + len(audio)] += audio
# Room: exponentially decaying noise impulse response (RT60 about 0.45 s).
ir_len = int(0.45 * RATE)
ir = rng.standard_normal(ir_len).astype(np.float32) * np.exp(-6.9 * np.arange(ir_len) / ir_len)
ir[0] = 1.0
ir /= np.abs(ir).sum() / 6
wet = np.convolve(mix, ir)[:total]
room = 0.6 * mix + 0.4 * wet / max(1e-6, np.abs(wet).max()) * np.abs(mix).max()
room += rng.standard_normal(total).astype(np.float32) * 0.004  # fan / HVAC hiss
room = room / max(1e-6, np.abs(room).max()) * 0.7
with wave.open("room-mic.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
    w.writeframes((room * 32767).astype(np.int16).tobytes())
with open("room-truth.tsv", "w") as f:
    for s, e, spk, text in truth:
        f.write(f"{s:.2f}\t{e:.2f}\t{spk}\t{text}\n")
print(f"total {t:.1f}s, {len(SCRIPT)} turns")
