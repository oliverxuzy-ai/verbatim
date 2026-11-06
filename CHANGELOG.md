# Changelog

Notable changes to Verbatim. Each release ships as a DMG on the
[Releases](https://github.com/oliverxuzy-ai/verbatim/releases) page; the full
release notes (in Chinese) are in [`release-notes/`](release-notes/).

## [0.6.0] - 2026-11-06

### Added
- Verbatim updates itself. It checks GitHub Releases every 6 hours,
  downloads a new version in the background, verifies it, and restarts into
  it when you aren't recording or using it. "Update to x" in the menu bar
  installs it right away. Settings → General → Updates turns it off or
  checks by hand. Works when Verbatim runs from the Applications folder.
- "Continue recording" on a finished meeting: in the meeting's top bar, in
  the menu bar for a meeting that stopped in the last two hours, and on the
  "stopped automatically" toast and notification. The new part is added to
  the same transcript and audio, right after where it stopped; the break in
  between isn't recorded and isn't counted in the duration. A line in the
  transcript marks where it continued. The whole meeting is refined again
  when it stops.

### Fixed
- A crash, force quit or hang while recording no longer loses the
  transcript. Every recognized line is written to disk as it arrives, the
  recording autosaves every 5 seconds, and on the next launch Verbatim
  restores the interrupted meeting and offers Refine to rebuild the rest
  from the audio.

## [0.5.1] - 2026-10-22

### Fixed
- The refine pass now keeps every voice it finds. Before, several similar
  remote voices that the refine had separated were folded back into the few
  live speakers (a real team meeting went from 5 remote speakers to 2). Now
  only the best match keeps the live name; the others stay as new speakers
  for you to name. Old meetings can be refined again from the "…" menu.
- A confirmed voiceprint is no longer matched to two speakers at once.
- Clicking a line, or "Play sample" on a speaker, plays the right audio when
  the call audio started later than the recording (for example while waiting
  for others to join). Your own lines no longer start half a second late.

## [0.5.0] - 2026-10-19

### Added
- Recording stops automatically when the meeting is over: call audio silent
  for 3 minutes and you silent for 2 (once the calendar slot has ended), or
  nobody talking for 10 minutes (20 before anyone has spoken). A 60-second
  countdown and a notification let you keep recording. On by default, can be
  turned off in Settings → Calendar → One-click start.

### Fixed
- The refine pass no longer fails on long and Chinese meetings with "The
  refined transcript missed speech that the live one caught". Missing lines
  are restored from the live transcript; the live version is kept only when
  more than 15% is missing.
- Chinese transcripts are compared by character, not by space-separated word.

### Changed
- Every pull request is built, tested and packaged on a GitHub-hosted Mac;
  releases are published from GitHub Actions.

## [0.2.0] - 2026-10-15

### Added
- Direct Google Calendar sign-in (no macOS Calendar needed), with attendees
  and meeting links.
- Rename a meeting with one click.
- A redesigned UI: warm paper tones, serif titles, a floating capsule and a
  new icon.
- DMG packaging (`scripts/package.sh`).

## [0.1.0] - 2026-10-15

- First version: live meeting transcription from the microphone and system
  audio, speaker separation, timestamps and Notion export.

[0.5.1]: https://github.com/oliverxuzy-ai/verbatim/releases/tag/v0.5.1
[0.5.0]: https://github.com/oliverxuzy-ai/verbatim/releases/tag/v0.5.0
