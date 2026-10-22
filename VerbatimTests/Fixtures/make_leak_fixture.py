"""Online meeting on laptop speakers, no echo cancellation: the mic hears the
user plus a quieter, delayed, reverberant copy of the call audio.
Input: mic.wav and system.wav from make_fixture.py. Output: mic-leak.wav.
Run: python3 -I make_leak_fixture.py <dir with mic.wav and system.wav>"""
import sys, wave
import numpy as np
d = sys.argv[1] if len(sys.argv) > 1 else "."
def read(p):
    with wave.open(p) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
mic, system = read(f"{d}/mic.wav"), read(f"{d}/system.wav")
rng = np.random.default_rng(3)
delay = int(0.045 * 16000)
ir = rng.standard_normal(int(0.3 * 16000)).astype(np.float32) * np.exp(-8 * np.arange(int(0.3 * 16000)) / (0.3 * 16000))
ir[0] = 1
ir /= np.abs(ir).sum() / 4
leak = np.convolve(system, ir)[: len(system)]
leak = np.concatenate([np.zeros(delay, dtype=np.float32), leak])[: len(mic)]
out = mic + 0.35 * leak / max(1e-6, np.abs(leak).max()) * np.abs(system).max()
out = out / max(1e-6, np.abs(out).max()) * 0.8
with wave.open(f"{d}/mic-leak.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes((out * 32767).astype(np.int16).tobytes())
print("wrote mic-leak.wav")
