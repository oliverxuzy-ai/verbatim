# Contributing to Verbatim

Thanks for helping! Bug reports, ideas and pull requests are all welcome.

- **Found a bug?** [Open a bug report](https://github.com/oliverxuzy-ai/verbatim/issues/new?template=bug_report.yml).
  Include your macOS version, the Verbatim version, the engine and the kind of
  meeting (online, in-room, which app). Never attach recordings or
  transcripts of real meetings without everyone's consent.
- **Have an idea?** [Open a feature request](https://github.com/oliverxuzy-ai/verbatim/issues/new?template=feature_request.yml)
  first for anything bigger than a small fix, so we can agree on the approach.
- **Security issue?** See [SECURITY.md](SECURITY.md); please don't file it publicly.

## Development setup

You need macOS 26, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate          # creates Verbatim.xcodeproj from project.yml
open Verbatim.xcodeproj
```

`Verbatim.xcodeproj` and `Info.plist` are generated from `project.yml`. Change
settings there, not in Xcode. The only package dependency is
[FluidAudio](https://github.com/FluidInference/FluidAudio).

### Tests

```bash
xcodebuild -project Verbatim.xcodeproj -scheme Verbatim \
  -derivedDataPath ~/Library/Developer/VerbatimDerivedData test
```

- The first run downloads the speech and speaker models.
- Keep DerivedData outside `~/Desktop` and `~/Documents`: the test fixtures
  live inside the test bundle, so unattended runs never trigger a folder
  access prompt.
- End-to-end tests run synthetic meetings (generated with macOS `say`, see
  `VerbatimTests/Fixtures/make_*.py`) through the real pipeline. The ones that
  need Apple's on-device speech recognition skip themselves where it is not
  available, such as GitHub's Mac runners. Please run the full suite on a real
  Mac when you touch transcription, diarization or refine code.
- The diarization benchmark uses real AMI meetings; see
  [`Bench/README.md`](Bench/README.md) for how to fetch the audio.

### Self-checks

The app has probe modes that run as the installed app, with its own
permissions, and write a JSON report:

```bash
open -n ~/Applications/Verbatim.app --args --probe-ui /tmp/ui.json
```

Clicks through a full recording with the real mouse: menu bar → record the
current meeting → pause / resume / stop in the capsule → main window and
refine → Export to Notion. The speakers play a two-person conversation as the
remote side. It creates a temporary "in progress" calendar event and deletes
it afterwards; recordings go to a temporary folder; the Notion page is real
(add `--no-export` to skip it). Screenshots are written next to the report.

```bash
open -n ~/Applications/Verbatim.app --args --probe-identify /tmp/id.json --title "A calendar meeting with two or more attendees"
```

Checks "confirm once, recognized later": records two sessions, confirms the
voices after the first, and names the second from voiceprints alone.

Others: `--probe-calendar <file> [--days N]`, `--probe-calendar-roundtrip <file> [--title "…"] [--say]`,
`--probe-recording <file>`, `--probe-system-audio <file>`.
Debug builds also have `--snapshot <dir>` (renders every surface with sample
data to PNGs, light and dark) and `--demo-session` (a fake live recording).

### Signing and permissions

Builds are ad-hoc signed with a designated requirement on the bundle ID (see
`OTHER_CODE_SIGN_FLAGS` in `project.yml`), so microphone and system audio
grants survive rebuilds. If the System Audio switch is on but nothing is
captured, toggle Verbatim off and on in Privacy & Security. To sign with your
own certificate, build with `VERBATIM_SIGN_IDENTITY="Your certificate"`.

## Project layout

```
Verbatim/
  App/            Entry point, AppModel, windows, hotkey, self-checks, snapshot mode
  Audio/          Microphone (AVAudioEngine + echo cancellation), system audio (Core Audio process tap), conversion
  Calendar/       Google sign-in and Calendar API, meeting reminders
  Recording/      Recording session, per-channel pipeline, live transcript, meeting-end detection
  Transcription/  Engine protocol, Apple and Soniox engines, live and offline diarization, refine, voiceprints, speaker naming
  Export/         Notion client and exporter
  Storage/        Recordings on disk
  UI/             Menu bar, capsule, main window, settings and onboarding
  Theme/          Colors, type, shared components
VerbatimTests/    Unit tests and end-to-end tests on synthetic meeting audio
Bench/            Diarization benchmark ground truth (AMI)
scripts/          DMG packaging, icon generation
release-notes/    Notes for each release
```

## Pull requests

1. Fork, create a branch, make your change.
2. Add or update tests for behavior changes.
3. Open a pull request using the template. CI builds and tests it on a
   GitHub-hosted Mac and attaches a DMG you and reviewers can install.

Conventions:

- Commit messages say what changes for the user in plain English, in the
  imperative: "Stop recording automatically when the meeting is over".
- Keep the UI text short and concrete.
- Use made-up names, emails and meetings in tests and sample data, never
  real people.
- Never commit API keys or tokens. The app keeps them in
  `~/Library/Application Support/Verbatim/secrets.json`; `.gitignore` guards
  against a copy landing in the repo.

## Releases (maintainers)

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion` +1) in
   `project.yml`, and keep the committed `Verbatim/Resources/Info.plist` in sync.
2. Write `release-notes/<version>.md` and add the entry to `CHANGELOG.md`.
3. Merge to `main`, then run the **Build** workflow on `main` from the Actions
   tab. It tests, packages the DMG, tags `v<version>` and publishes the release.

Local packaging: `scripts/package.sh` writes `build/Verbatim-<version>.dmg`.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
