# Multi-input recording + post-recording transcription

Date: 2026-11-15. Builds on the MVP (`feature/mvp`, spec `2026-06-12-meeting-recorder-design.md`).

## Why

The terminal workflow in `~/.claude/skills/interview-transcribe/` works better than the app:

- `scripts/record-meeting.sh` mixes **three** inputs (WF-1000XM6 earbuds + BlackHole 2ch at gain
  0.55, MacBook Air Microphone at 1.00). The app can only mix two (one "remote", one "mic").
- `scripts/run.sh` then converts to 16 kHz, transcribes with mlx-whisper large-v3-turbo and labels
  speakers with an ECAPA voiceprint (`~/.cache/diarize/voiceprint-<name>.npy`), producing
  `<Guest>_Transcript.md`. The app has no post-processing at all.

Goal: the app records exactly what the script records, and can produce the same transcript.

## Phase 1: N inputs

- `RecordingSettings.inputs: [InputConfig]` (see `Sources/RecorderCore/InputConfig.swift`) replaces
  `remoteDeviceName`, `micDeviceName`, `remoteVolume`, `micVolume`. Default = `InputConfig.defaultInputs`.
- Settings persisted before this change (legacy keys) migrate to two inputs: remote then mic with their
  saved volumes. Decoding is per-field tolerant (`decodeIfPresent` + defaults) so one bad/missing
  field no longer resets every setting.
- Preflight: at least one input; every input must have a device name; a missing device is an error
  unless `skipIfMissing`, in which case it is skipped and reported as a non-blocking notice. If every
  input would be skipped, that is an error.
- `CommandBuilder.arguments(inputs: [ResolvedInput], settings:, outputURL:)` builds, for input *i*:
  `[i:a]aresample=48000,aformat=channel_layouts=mono,volume=G,astats=…,ametadata=…[in<i>]`
  then `[in0]…[inN-1]amix=inputs=N:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95[mixed]`.
  With the default three inputs and meters stripped, the filtergraph must equal the script's.
- Level meters: one per input. The ametadata filter of branch *i* is `Parsed_ametadata_<5*i+4>`.
  `LevelLineParser` returns the input position; `RecordingController` publishes `levelsDB: [Double]`.

## Phase 2: transcription

- The pipeline is vendored in `Pipeline/` (copied from the skill, kept CLI-compatible with it) and
  bundled into the app's Resources by `Scripts/make_app.sh`. It shares `~/.cache/diarize` (venv,
  models, voiceprint) with the skill, so no second setup and no second voiceprint.
- Vendored changes vs. the skill:
  - The cache key must be unique per recording file (the app names every file `meeting.flac` inside
    a timestamped folder, so the skill's `guest + basename` key would reuse a stale transcript).
  - `diarize.py` additionally writes `<Guest>_Transcript.summary.json` next to the transcript
    (turns, duration, speaking seconds per label, identification method + scores, weak-match flag,
    count of `(?)` turns) and prints `STAGE: <name>` lines so the app can show progress.
  - Output goes next to the recording (the recording's folder).
- `TranscriptionController` (RecorderCore) runs `Pipeline/run.sh` via `ProcessRunning`, with `PATH`
  including `/opt/homebrew/bin:/usr/local/bin` (apps launched from Finder have a minimal PATH),
  publishes stage/progress, supports cancel, and on success parses the summary JSON into a
  `TranscriptionResult`.
- UI: after "Saved", a guest-name field + **Transcribe** button (or automatic when
  `TranscriptionSettings.autoTranscribe`), progress, then the summary (turns, speaking time,
  identification + weak-match warning, `(?)` count) with **Open transcript** / **Show in Finder**.

## Known limits (from the pipeline itself)

- Two speakers only, labelled Interviewer / Interviewee.
- Apple Silicon only (mlx-whisper). First run downloads models.
