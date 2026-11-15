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

The inputs are edited in the main window, in the **Audio Inputs** list: one row per
input with a device picker, a gain slider, "Skip if missing" and a remove button, plus
**Add input** and **Reset to defaults** under the list. A missing device that is not
marked "skip if missing" blocks the recording and names the device. Each input has its
own level meter while recording, and the inputs cannot be changed until it stops. With
more inputs than fit on the screen the list scrolls. Settings (gear icon) holds the
filename prefix, one-folder-per-recording, the ffmpeg path and the transcription options.

Stop a recording with **Stop Recording** or Cmd-. (Command-period). Esc does nothing, so
a stray keypress cannot end a capture.

Settings saved by older versions (one remote device plus one microphone) are
migrated to two inputs automatically.

### Audio routing

The far side of a call only reaches BlackHole if the call app's speaker output
(or the system output) is set to the **ToRecord** multi-output device, which
plays to your earbuds/speakers and to BlackHole 2ch at the same time. Your own
voice comes in through the microphone input.

Recordings are saved to `~/Documents/Recordings/meetings/<timestamp>/meeting.flac`.

## Transcribe

The **Transcription** section at the bottom of the main window always shows one audio
file, named as `<recording folder>/<file>` (every recording is called `meeting.flac`, so
the folder tells them apart). Everything runs locally; no audio leaves the machine.

1. **A saved recording** appears there with a guest-name field (its placeholder is the
   default guest name from Settings) and a **Transcribe** button. With *Transcribe
   automatically after recording* switched on in Settings, it starts by itself on save,
   using the default guest name; you can re-run with another name afterwards.
2. **An existing file:** **Transcribe a file…** (top right of the section) opens a file
   picker for flac, wav, m4a and mp3. The panel then shows that file, ready for a guest
   name and **Transcribe**.
3. **Running:** the stage ("Converting audio…", "Transcribing…", "Identifying
   speakers…"; "Setting up (first run only)…" while the Python environment is created),
   a progress bar (determinate during the Transcribing stage, indeterminate otherwise),
   the elapsed time and **Cancel** (it reads "Cancelling…" until the pipeline has
   stopped).
4. **Finished:** turns, duration, speaking time per person in minutes, how the
   interviewer was identified (the voiceprint similarity of each speaker), the number of
   uncertain `(?)` turns, and how long it took. If the voice match was weak, an orange
   "Weak voice match — check the labels by reading the first turns" warning appears.
   **Open transcript** opens the `.md` in its default app, **Show in Finder** selects
   it, **Transcribe again…** returns to the guest-name field (to re-run with another
   name).
5. **Failed:** the error, a "Pipeline output" disclosure with the last lines of the
   pipeline's output, and **Retry**. **Cancelled:** a short note and **Transcribe
   again**.

Recording and transcribing are independent: you can start a new recording while a
transcription runs. A transcription stays tied to the file it was started for. A
recording saved meanwhile shows up as "New recording saved: …" with a **Transcribe…**
button once the run has ended (with auto-transcribe on it starts by itself after a
successful run). When the panel moves to another file, the last transcript stays as an
"Earlier: …" line with **Open** and **Show**, with its weak-match warning if it had one.
Quitting the app (Cmd-Q or closing the window) while a transcription runs asks for
confirmation and then cancels it.

Settings (gear icon), "Transcription" group: *Transcribe automatically after
recording*, *Interviewer name*, *Default guest name* and *Pipeline folder* (type a path
or **Choose…**, **Clear** goes back to the bundled copy). The sheet shows which pipeline
will be used, or a red "Pipeline not found".

- Pipeline: mlx-whisper `large-v3-turbo` for the text, plus a voiceprint
  (SpeechBrain ECAPA) to decide who is speaking. The pipeline is bundled with the
  app (`Pipeline/`) and is CLI-compatible with the `interview-transcribe` skill.
- Shared with that skill: the environment, models and voiceprint live in
  `~/.cache/diarize`, so there is no second setup.
- First run downloads the models and sets up the environment, which takes a
  while. After that expect roughly 1-2 minutes per 10 minutes of audio.
- Output: `<Guest>_Transcript.md` and `<Guest>_Transcript.summary.json` (turns,
  duration, speaking time per speaker, how the interviewer was identified, weak-match
  flag, count of uncertain `(?)` turns). They go in the audio file's own folder, or, if
  that folder holds other audio files (flac, wav, m4a, mp3), in a `<audio name>
  transcript/` folder next to the audio; the panel says so before you start. A
  transcript with the same guest name in the output folder is replaced, and the panel
  warns about that too.
- The text is raw Whisper output: proper names are often misspelled and words at a
  speaker change can land in the neighbouring turn. Check the first turns, and the
  `(?)` ones, against the audio.
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
