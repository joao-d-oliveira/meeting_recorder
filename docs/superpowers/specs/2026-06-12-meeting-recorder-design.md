# Local Meeting Audio Recorder for macOS — Design Spec

**Date:** 2026-06-12
**Status:** Approved design, pre-implementation

## Summary

A native SwiftUI macOS app that wraps the user's proven ffmpeg recording pipeline
(avfoundation capture → per-input gain → amix → alimiter → FLAC) in a simple window UI.
It removes the fragile parts of the manual workflow: numeric avfoundation device IDs,
hand-edited volume values, terminal start/stop, and manual output-folder management.

Full product requirements live in the PRD (provided by the user, 2026-06-12). This spec
records the technical design decisions and architecture.

## Decisions made

| Decision | Choice | Rationale |
|---|---|---|
| Tech stack | Native SwiftUI (Swift) | Lightweight, native CoreAudio/permission APIs, real .app |
| Recording engine | ffmpeg subprocess | Reuses the proven pipeline; lowest audio-path risk |
| App shape | Single window app + settings sheet | Matches PRD suggested UI; menu bar item deferred |
| Level meters | In MVP, parsed from ffmpeg stderr | "Is the other side captured?" is the workflow's #1 failure mode |
| Sandboxing | Not sandboxed | Must exec Homebrew ffmpeg and write arbitrary folders; locally built personal tool |
| Distribution | Built locally via Xcode | No App Store, no notarization needed for MVP |

## Architecture

Five core units plus views. Each unit has one purpose, a defined interface, and is
testable in isolation.

### DeviceManager
- Runs `ffmpeg -hide_banner -f avfoundation -list_devices true -i ""` and parses the
  stderr listing into `[AudioDevice(name: String, index: Int)]` (audio devices only).
- This is intentionally the same enumeration ffmpeg uses at record time, so the
  name→index mapping cannot drift from what `-i ":N"` will actually open.
- Rescans on app launch and on the manual Refresh button. (CoreAudio device-change
  notifications are a possible later enhancement; manual refresh satisfies PRD §5.7.)

### FFmpegLocator
- Resolution order: user-configured path → `/opt/homebrew/bin/ffmpeg` →
  `/usr/local/bin/ffmpeg` → `PATH` lookup via `/usr/bin/env`.
- If not found: recording is blocked and the UI shows a setup message with
  `brew install ffmpeg` instructions (PRD §5.6, acceptance "Missing ffmpeg").

### CommandBuilder
- Pure function: `(RecordingSettings, resolvedIndices, outputURL) → [String]` (ffmpeg args).
- Generated pipeline mirrors the user's working command:
  - per input: `-thread_queue_size 1024 -f avfoundation -i ":N"`
  - filter graph: `aresample=48000, aformat=channel_layouts=mono, volume=<gain>` per
    branch → `amix=inputs=2:duration=longest:dropout_transition=0:normalize=0` →
    `alimiter=limit=0.95`
  - each input branch additionally runs `astats` with metadata printing to stderr so
    the app can read live levels (see Level meters).
  - codec by selected format: FLAC `flac`, WAV `pcm_s16le`, MP3 `libmp3lame`, M4A `aac`.
- Defaults: remote volume 0.55, mic volume 1.00, mono, limiter on, normalize off, FLAC.
- Purity makes it fully unit-testable: settings in, exact arg array out.

### RecordingController
- Owns the ffmpeg `Process`. Responsibilities:
  - Start: launch with args from CommandBuilder; pipe stdin and stderr.
  - Monitor: background task reads stderr line-by-line; level lines feed the meters,
    everything is kept in a rolling ~200-line buffer for error display.
  - Stop: write `q` to stdin (ffmpeg's clean-shutdown path — finalizes the file
    header); if the process has not exited after 5 s, send SIGINT; after 5 more
    seconds, SIGKILL.
  - Verify: after exit, check the output file exists and is non-empty before
    reporting success.
  - Unexpected exit (nonzero status while state is "recording"): transition to an
    error state and surface the last ~20 stderr lines in a disclosure view. The
    partial file is kept (FLAC/WAV are streamable; a crash-cut file still plays).
- A thin `ProcessRunning` protocol abstracts `Process` so tests can substitute a fake.

### SettingsStore
- `UserDefaults`-backed. Persists: remote device **name**, mic device **name**
  (never numeric indices — PRD §5.7), remote/mic volumes, output format, output
  folder, filename prefix, one-folder-per-recording flag, ffmpeg path override.
- Last-used configuration restores on launch (PRD §7 "save previous configuration").

### PreflightValidator
Runs when Start is pressed; each failure produces a specific, actionable message:
1. Remote source selected and present in the current device scan.
2. Mic source selected and present in the current device scan.
3. Output folder exists or can be created (create it if possible).
4. ffmpeg resolved by FFmpegLocator.
5. Microphone permission granted (`AVCaptureDevice.authorizationStatus`); if not
   determined, request; if denied, show a deep link to
   System Settings → Privacy & Security → Microphone.

A previously saved device name missing from the current scan disables Start and shows
an inline warning naming the missing device (acceptance "Missing device").

## Data flow

1. User selects devices by **name** in dropdowns; names persist via SettingsStore.
2. On Start: DeviceManager rescans → names resolve to current indices →
   PreflightValidator runs → CommandBuilder emits args → RecordingController launches
   ffmpeg.
3. While recording: stderr level lines update meters (~10 Hz), elapsed timer ticks,
   Stop button is active.
4. On Stop: clean shutdown → file verification → "Saved to …" confirmation with a
   Reveal in Finder button.

### Output layout (PRD §5.5)
```
~/Documents/Recordings/meetings/YYYY-MM-DD_HH-MM-SS/meeting.flac
```
Folder, prefix, format, and per-recording-folder behavior are configurable in Settings.

## Level meters

- Each input branch includes `astats=metadata=1:reset=1` followed by
  `ametadata=mode=print` keyed to the overall RMS level, printing to stderr.
- RecordingController regex-parses RMS dB values per input, throttles UI updates to
  ~10 Hz, and drives two horizontal bars (Remote, Mic) colored by level.
- No third "mixed" meter in MVP — the two input meters answer the operative question
  ("are both sides alive?").
- Exact astats/ametadata syntax to be validated against the installed ffmpeg version
  during implementation; the fallback if per-branch metadata proves noisy is a single
  `ebur128` meter on the mixed output plus a dead-input warning derived from it.

## Permissions

- `NSMicrophoneUsageDescription` in Info.plist.
- `AVCaptureDevice.requestAccess(for: .audio)` before first recording; the ffmpeg
  child process inherits the app's TCC grant (responsible-process attribution).
- BlackHole capture needs no extra permission (it is an input device).
- No screen-recording permission needed (audio-only avfoundation capture).

## UI

**Main window** (single compact view):
- Remote source dropdown, Mic source dropdown, Refresh devices button
- Remote volume slider (0–150%, default 55%), Mic volume slider (default 100%)
- Output folder display + change button, format picker
- Start/Stop button, elapsed timer, two level meters
- Status line (idle / recording / saved / error) with disclosure for error details

**Settings sheet:**
- Default output folder, filename prefix, default format
- Default volumes, ffmpeg path override
- One-folder-per-recording toggle

## Testing

- **Unit tests:** device-list parser (fixture stderr captured from real ffmpeg output),
  CommandBuilder (settings → exact arg arrays, all four formats), stderr level-line
  parser (fixture lines).
- **Controller tests:** `ProcessRunning` fake to exercise start/stop/unexpected-exit
  state transitions without launching real processes.
- **Manual end-to-end:** record ~10 s with BlackHole 2ch + built-in mic, confirm the
  file plays and contains both sides; kill ffmpeg mid-recording and confirm the error
  path and partial-file handling.

## Out of scope for MVP (per PRD §7–8)

Presets (§5.8), pause/resume, timestamp markers, meeting titles/notes, menu bar item,
transcription, cloud sync, video, automatic meeting detection. "Save previous
configuration" covers the single-user preset need.
