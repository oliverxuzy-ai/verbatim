import subprocess, wave, sys, os
# (channel, voice, text)
script = [
    ("system", "Samantha", "Hi everyone, thanks for joining. Today I want to review the semantic layer proof of concept and the Snowflake cost numbers."),
    ("mic", "Reed (英语（美国）)", "Sounds good. I finished the dbt comparison yesterday, and the results look promising."),
    ("system", "Daniel", "Great. Before we dive in, can you remind us what the monthly API limit is for the dbt Cloud semantic layer?"),
    ("mic", "Reed (英语（美国）)", "It is about twenty thousand calls per month, whether we use them or not."),
    ("system", "Samantha", "Okay. And how much could we save on the AI functions if we move some of them to rule based logic?"),
    ("system", "Daniel", "I think the estimate was around forty to fifty percent of the current usage."),
    ("mic", "Reed (英语（美国）)", "Right, that matches my numbers. I will send the detailed breakdown after this meeting."),
    ("system", "Samantha", "Perfect. Let's schedule a follow up next Wednesday to make the final decision."),
]
rate = 16000
timeline = {"system": [], "mic": []}
t = 0.6
os.makedirs("parts", exist_ok=True)
for i, (ch, voice, text) in enumerate(script):
    path = f"parts/{i}.wav"
    subprocess.run(["say", "-v", voice, "--data-format=LEI16@16000", "-o", path, text], check=True)
    with wave.open(path) as w:
        frames = w.readframes(w.getnframes())
        dur = w.getnframes() / rate
    timeline[ch].append((t, frames))
    print(f"{t:6.2f}-{t+dur:6.2f} {ch:6} {voice:6} {text[:50]}")
    t += dur + 0.7
total = t + 1.0
for ch in ("system", "mic"):
    buf = bytearray(int(total * rate) * 2)
    for start, frames in timeline[ch]:
        off = int(start * rate) * 2
        buf[off:off+len(frames)] = frames
    with wave.open(f"{ch}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(bytes(buf))
print("total", round(total, 2))
