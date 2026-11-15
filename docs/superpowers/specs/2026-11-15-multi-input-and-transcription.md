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
  `RecordingSettings.transcription: TranscriptionSettings` holds the Phase 2 preferences.
- Settings persisted before this change (legacy keys) migrate to two inputs: remote then mic with their
  saved volumes (0.55 / 1.00 if a volume is missing). A legacy side with no device name is dropped; if
  both are dropped (the user never picked a device) the defaults apply. Decoding is per-field tolerant
  (`decodeIfPresent` + defaults, also inside each `InputConfig` and for each element of `inputs`) so one
  bad/missing field no longer resets every setting. The `SettingsStore` key (`settings.v1`) is unchanged;
  the legacy keys are read for migration and never written back.
- `InputResolver.resolve(inputs:devices:)` matches inputs to the scanned devices by exact name and returns
  an `InputResolution`: `recorded` (config + `ResolvedInput`, in configured order), `skipped`
  (disconnected, `skipIfMissing`), `missing` (disconnected, blocking) and `unnamedPositions` (blank
  device name, blocking). `resolvedInputs` is what the command builder takes.
- Preflight returns a `PreflightResult`: `issues` (blocking; Start is allowed only when empty), `notices`
  (non-blocking, one `inputSkipped(deviceName:)` per skipped device) and the `InputResolution`.
  Issues: no inputs; an input without a device name (1-based position); a missing device not marked
  `skipIfMissing`; every input skipped (only reported when no more specific input problem exists);
  plus ffmpeg / microphone access / output folder as before.
- `CommandBuilder.arguments(inputs: [ResolvedInput], settings:, outputURL:)` builds, for input *i*:
  `[i:a]aresample=48000,aformat=channel_layouts=mono,volume=G,astats=…,ametadata=…[in<i>]`
  then `[in0]…[inN-1]amix=inputs=N:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95[mixed]`.
  With the default three inputs and meters stripped, the filtergraph must equal the script's
  (`CommandBuilder.filterGraph(gains:includeMeters:)`; tests compare against the script text, and run the
  generated graph through real ffmpeg with `sine` sources for 1, 2 and 3 inputs).
- Level meters: one per input. The ametadata filter of branch *i* is `Parsed_ametadata_<5*i+4>`
  (`CommandBuilder.ametadataInstanceID(forInput:)`). `LevelLineParser(inputCount:)` returns the input
  position (`LevelSample.inputIndex`); `RecordingController.start(…, inputCount:)` publishes
  `levelsDB: [Double]` (one entry per recorded input, silence floor on start, 10 Hz per input).
- UI: one row per input (device picker that keeps a disconnected saved name visible, gain slider + value,
  "Skip if missing", live meter while recording, remove), **Add input**, **Reset to defaults**. Inputs
  are read-only while recording or stopping. Skipped devices are shown as notices and never block Start.

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
