# Meeting Recorder

Native macOS app that records meeting audio locally by mixing several audio
inputs (call audio via BlackHole, your earbuds, your microphone) with ffmpeg,
and can turn a saved recording into a speaker-labelled transcript, all on this
Mac.

## Requirements

- macOS 14+
- ffmpeg (`brew install ffmpeg`)
- A loopback audio device such as [BlackHole](https://github.com/ExistentialAudio/BlackHole) 2ch
- For transcription: an Apple Silicon Mac and [uv](https://docs.astral.sh/uv/) (`brew install uv`)

## Build & run

```bash
./Scripts/make_app.sh
open build/MeetingRecorder.app
```

## Recording

The app mixes N inputs into one FLAC. The defaults match
`~/.claude/skills/interview-transcribe/scripts/record-meeting.sh`:

| Input | Gain | Notes |
|---|---|---|
| WF-1000XM6 (earbuds) | 0.55 | Skipped, with a notice, if not connected |
| BlackHole 2ch | 0.55 | The far side of the call |
| MacBook Air Microphone | 1.00 | Your voice |

The inputs are editable in the app's Settings (device name, gain, whether a
missing device is skipped or blocks the recording). Each input has its own level
meter while recording. A missing device that is not marked "skip if missing"
blocks the recording and names the device.

Settings saved by older versions (one remote device plus one microphone) are
migrated to two inputs automatically.

### Audio routing

The far side of a call only reaches BlackHole if the call app's speaker output
(or the system output) is set to the **ToRecord** multi-output device, which
plays to your earbuds/speakers and to BlackHole 2ch at the same time. Your own
voice comes in through the microphone input.

Recordings are saved to `~/Documents/Recordings/meetings/<timestamp>/meeting.flac`.

## Transcribe

After a recording is saved, use the Transcribe button (enter the guest's name
first; there is also an auto-transcribe option in Settings). Everything runs
locally; no audio leaves the machine.

- Pipeline: mlx-whisper `large-v3-turbo` for the text, plus a voiceprint
  (SpeechBrain ECAPA) to decide who is speaking. The pipeline is bundled with the
  app (`Pipeline/`) and is CLI-compatible with the `interview-transcribe` skill.
- Shared with that skill: the environment, models and voiceprint live in
  `~/.cache/diarize`, so there is no second setup.
- First run downloads the models and sets up the environment, which takes a
  while. After that expect roughly 1-2 minutes per 10 minutes of audio.
- Output, next to the recording: `<Guest>_Transcript.md` and
  `<Guest>_Transcript.summary.json` (turns, duration, speaking time per speaker,
  how the interviewer was identified, weak-match flag, count of uncertain `(?)`
  turns). The app shows this summary and can open the transcript.
- Two speakers only, labelled Interviewer and Interviewee.
- Needs an existing voiceprint at `~/.cache/diarize/voiceprint-<name>.npy`
  (name = the interviewer name in Settings). The `interview-transcribe` skill
  creates it from two or more recordings of you; the app does not.

## Development

```bash
swift build                   # compile
swift run RecorderCoreTests   # run the test suite
swift run MeetingRecorder     # run the app unbundled (no mic permission prompt)
```

A Command Line Tools-only setup (no Xcode) builds fine as long as the app uses no
SwiftUI property-wrapper macros: keep view state such as `@State` in `AppModel` instead.

Manual end-to-end checklist: `docs/superpowers/plans/2026-11-15-e2e-checklist.md`.
Design: `docs/superpowers/specs/2026-11-15-multi-input-and-transcription.md`.
