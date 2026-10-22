# Diarization benchmark data

Real meetings from the [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/) (CC BY 4.0):
single far-field microphone (`Array1-01`), four speakers, overlapping speech.
Ground truth RTTM files come from [pyannote/AMI-diarization-setup](https://github.com/pyannote/AMI-diarization-setup) (only_words, test split).

The tests read them from `~/Library/Caches/VerbatimBench/ami` (outside ~/Desktop, so no folder-access prompt). Fetch with:

```bash
mkdir -p ~/Library/Caches/VerbatimBench/ami && cp Bench/ami/*.rttm ~/Library/Caches/VerbatimBench/ami/
```

```bash
for m in ES2004a IS1009a; do curl -fo ~/Library/Caches/VerbatimBench/ami/$m.Array1-01.wav "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/$m/audio/$m.Array1-01.wav"; done
```

Then run `xcodebuild … test -only-testing:VerbatimTests/DiarizationBenchmarkTests`.
