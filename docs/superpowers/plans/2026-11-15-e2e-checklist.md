# Manual end-to-end checklist: multi-input recording + transcription

Date: 2026-11-15. Extends and replaces the Task 12 Step 4 checklist in
`2026-06-12-meeting-recorder-mvp.md`. Spec: `../specs/2026-11-15-multi-input-and-transcription.md`.
Run at the keyboard, on the built app (`./Scripts/make_app.sh && open build/MeetingRecorder.app`).
Tick a box only when the expected result was observed; note failures next to the item.

## 0. Setup

- [ ] **Audio routing.** In Audio MIDI Setup confirm the **ToRecord** multi-output device exists (earbuds/speakers + BlackHole 2ch). Set the system output (or the call app's speaker) to ToRecord.
  Expected: sound still plays in your earbuds/speakers.
- [ ] **Test source.** Open a test call or a video with speech, with its audio going to ToRecord.
  Expected: you can hear it, and BlackHole receives it.
- [ ] **Inputs present.** `ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i -E "WF-1000XM6|BlackHole|MacBook Air Microphone"` (or `record-meeting.sh --check`).
  Expected: all three devices are listed with an index.
- [ ] **Defaults.** Look at the **Audio Inputs** list in the main window (fresh settings, or click **Reset to defaults**), then open Settings with the gear icon.
  Expected: three inputs in order: WF-1000XM6 (gain 0.55, skip if missing), BlackHole 2ch (0.55), MacBook Air Microphone (1.00). The Settings sheet says "Using ffmpeg at /opt/homebrew/bin/ffmpeg" and "Using pipeline at ..." (no red "Pipeline not found"). Close it with Done.
- [ ] **Window size.** With the three inputs and a finished transcription showing (section 5), compare the window with the screen (also while recording).
  Expected: the whole window fits on the laptop display without resizing; the inputs list scrolls instead of the window growing, and the Transcription section is fully visible.

## 1. Three-input recording

- [ ] Click Start Recording (grant mic permission if prompted).
  Expected: status shows Recording, timer ticks, no error.
- [ ] While the test audio plays and you speak, watch the meters.
  Expected: one meter per input (three); earbuds meter moves with the earbuds mic/your voice pickup, BlackHole meter moves with the test audio, MacBook mic meter moves when you speak. Each moves independently (mute the test audio: only BlackHole drops; stop talking: the mic one drops).
- [ ] Record about 1 minute, click Stop Recording.
  Expected: stops promptly, status shows Saved with the file name, no error or "exited unexpectedly" message.
- [ ] `afplay "$(ls -t ~/Documents/Recordings/meetings/*/meeting.flac | head -1)"`
  Expected: far-side audio and your voice are both audible, no dropouts, no clipping/distortion.
- [ ] `flac -t "$(ls -t ~/Documents/Recordings/meetings/*/meeting.flac | head -1)"`
  Expected: passes (no "invalid residual").

## 2. Device-missing handling

- [ ] Disconnect the WF-1000XM6 earbuds (or turn them off), then Start Recording.
  Expected: recording proceeds with two inputs; a non-blocking notice names the skipped earbuds. Only two meters appear (or the earbuds meter is absent/idle). Stop: Saved, file plays with the other two inputs.
- [ ] Reconnect the earbuds, Start again.
  Expected: three inputs again, no notice.
- [ ] In the main window untick **Skip if missing** on the earbuds row, disconnect the earbuds (or turn them off), then Start Recording.
  Expected: Start is blocked; the message names the missing device ("Device "WF-1000XM6" is not available..."); no recording is created. Tick Skip if missing again afterwards.
- [ ] Remove the BlackHole and MacBook microphone rows (minus buttons), keep the earbuds row with Skip if missing on, disconnect the earbuds, Start.
  Expected: blocked, with "None of the selected devices are connected, so there is nothing to record." Click **Reset to defaults** afterwards.
- [ ] Remove all inputs (minus buttons), Start.
  Expected: blocked with "Add at least one audio input." Then click **Add input** repeatedly until a row shows "Select…" (all connected devices used), Start: blocked with "Input N has no device selected." Click **Reset to defaults** afterwards.
- [ ] Pick the same device in two rows, Start.
  Expected: blocked, naming the device that would be recorded twice. Click **Reset to defaults** afterwards.
- [ ] Settings (gear icon) > ffmpeg path override = `/nonexistent/ffmpeg`, Done, Start.
  Expected: error says ffmpeg was not found and how to install it. Clear the override in Settings; "Using ffmpeg at /opt/homebrew/bin/ffmpeg" reappears.

## 3. Parity with record-meeting.sh

- [ ] Record the same ~1 minute twice, same sources, same room: once with the app, once with `~/.claude/skills/interview-transcribe/scripts/record-meeting.sh` (stop with Ctrl-C, wait for `Saved:`). Play the same test clip both times and say the same sentence at the same point.
  Expected: both files are 48 kHz mono FLAC (`ffprobe -hide_banner <file>`), similar duration (within a couple of seconds).
- [ ] Compare levels: `ffmpeg -i <file> -af ebur128=peak=true -f null - 2>&1 | tail -12` on each (or `volumedetect`).
  Expected: integrated loudness and peak within about 1 dB of each other; neither clips (peak below 0 dBFS).
- [ ] Listen to both back to back.
  Expected: the same balance between far side and your voice; no audible difference in tone or limiting.

## 4. Crash and force-quit flow

- [ ] Start a recording, then run `pkill -9 -f "ffmpeg.*avfoundation"`.
  Expected: the app shows "ffmpeg exited unexpectedly" (with the ffmpeg output disclosure), not Saved; the partial `meeting.flac` plays up to the cut.
- [ ] Start a recording, record 10-15 s, then force-quit the app (Activity Monitor or `kill -9` on the app).
  Expected: after relaunch the app is idle with no stuck state; the partial file is playable (`afplay`). Check no orphan ffmpeg is left running: `pgrep -fl ffmpeg` shows nothing (kill it if it does, and note it).
- [ ] Start a recording, then Cmd-Q the app.
  Expected: the recording is stopped cleanly first; the file plays.

## 5. Transcription

Prerequisite: a voiceprint exists at `~/.cache/diarize/voiceprint-<name>.npy` (`<name>` = *Interviewer name* in Settings; `ls ~/.cache/diarize/`). Use a real recording with a clear interviewer/guest exchange (at least a few minutes), ideally one recorded in section 1.

The **Transcription** section sits at the bottom of the main window. Its first line names the file it is about, as `<recording folder>/<file>`.

- [ ] Record about 20 s with auto-transcribe off, stop.
  Expected: after "Saved" the Transcription section shows `<timestamp folder>/meeting.flac`, a guest-name field whose placeholder is the default guest name ("Guest"), and a **Transcribe** button. Nothing starts by itself.
- [ ] Enter a guest name (e.g. `TestGuest`) in the field and click **Transcribe** (or press Return in the field).
  Expected: the form is replaced by the running view: a stage title that changes over time ("Converting audio…", "Transcribing…", "Identifying speakers…"), an elapsed-time counter ticking each second, "Guest: TestGuest", and a **Cancel** button. During "Transcribing…" the bar is determinate with a percentage that rises; in the other stages it is indeterminate. First run only: "Setting up (first run only)…" with a note, and models download, so it takes noticeably longer.
- [ ] Wait for completion.
  Expected: a green "Transcript ready: TestGuest_Transcript.md" line and a table with: Turns, Duration, Speaking time (one line per person, "Joao (Interviewer): x.x min" and "TestGuest (Interviewee): y.y min", adding up to roughly the duration), Identified by ("saved voiceprint (Joao 0.9x, TestGuest 0.xx)"), Uncertain turns (?), and Took (roughly 1-2 min per 10 min of audio). Buttons: **Open transcript**, **Show in Finder**, **Transcribe again…**.
- [ ] Check the scores.
  Expected: the interviewer's score about 0.9+ and the guest's well under 0.5. No orange "Weak voice match" warning for a good recording.
- [ ] Check the `(?)` count against the file: `grep -c '(?)' <Guest>_Transcript.md`.
  Expected: the number matches "Uncertain turns (?)" (low for a clean recording).
- [ ] Files next to the recording: `ls "$(dirname "$(ls -t ~/Documents/Recordings/meetings/*/meeting.flac | head -1)")"`
  Expected: `TestGuest_Transcript.md` and `TestGuest_Transcript.summary.json` sit beside `meeting.flac` (not in `~/Recordings` or elsewhere). The JSON has turns, duration, speaking seconds per label, identification, weak-match flag.
- [ ] Click **Open transcript**, then **Show in Finder**.
  Expected: the transcript opens in the default app; Finder opens with the transcript selected.
- [ ] Read the first ~10 turns and the last 3-4 in the transcript.
  Expected: the interviewer opens, asks the questions and closes; the guest answers. Labels read `<Interviewer> (Interviewer)` and `TestGuest (Interviewee)`, with timestamps. Wrong labels, missing turns, or text out of order are failures. Known quirks that are not failures: words at a speaker change landing in the neighbouring turn, misheard short phrases, misspelled proper names.
- [ ] Click **Transcribe again…**.
  Expected: back to the guest-name field for the same file; typing `TestGuest` again shows an orange "TestGuest_Transcript.md already exists in this folder and will be replaced." note.
- [ ] Weak match: transcribe a recording where the interviewer's voice is absent or very quiet (e.g. only the BlackHole input has speech, or a recording of two other people).
  Expected: an orange "Weak voice match — check the labels by reading the first turns" warning in the summary and a low score; some turns may be marked `(?)`.
- [ ] Two recordings, same guest name, separate folders: transcribe a second, different recording with the same guest name.
  Expected: the second transcript is for the second recording (different content/timestamps), not a stale copy of the first, and it is written in the second recording's folder.
- [ ] **Transcribe a file…**: click it (top right of the section), pick an older `.flac` (or a `.wav`/`.m4a`/`.mp3`), enter a guest name, **Transcribe**.
  Expected: the file picker offers only audio files; the section switches to the chosen file's `<folder>/<name>`; the transcript is written in that file's folder. The button is disabled while a transcription runs.
- [ ] Auto-transcribe: enable *Transcribe automatically after recording* in Settings, record 20-30 s, stop.
  Expected: transcription starts on its own after "Saved" (running view straight away), using the default guest name ("Guest_Transcript.md"). Disable it again afterwards.

### Recording while transcribing

- [ ] Start a transcription of a longer recording (5+ minutes), then Start Recording and record 20-30 s while it runs (also try this with auto-transcribe on).
  Expected: recording is unaffected (meters live, no dropouts when played back; note any). The Transcription section keeps showing the running file and its progress. When the new recording is saved, a "New recording saved: <folder>/meeting.flac" line with **Transcribe…** (disabled until the run ends) appears below it; it does not replace the running view. With auto-transcribe on, the new recording starts right after the first run finishes successfully.
- [ ] After the first run has finished, click **Transcribe…** on that line (auto-transcribe off).
  Expected: the section switches to the new file with the guest-name field, and an "Earlier: TestGuest_Transcript.md (<folder>/meeting.flac)" line with **Open** and **Show** remains below (with "— weak voice match" and an orange icon if that run was weak).

### Cancel

- [ ] Start a transcription of a longer recording (5+ minutes), and click **Cancel** during the transcribe stage.
  Expected: the button reads "Cancelling…" and is disabled; within a few seconds the section shows "Transcription cancelled." (not an error), no transcript/summary file is left half-written, and `pgrep -fl "mlx_whisper|diarize|run.sh"` shows no leftover processes. **Transcribe again** works, and a re-run completes.
- [ ] Start a transcription, then Cmd-Q.
  Expected: an alert "A transcription is in progress. Cancel it and quit?"; **Don't Quit** keeps everything running. **Cancel Transcription & Quit** quits within about 6 seconds and `pgrep -fl "mlx_whisper|diarize|run.sh"` shows nothing afterwards.
- [ ] Start a recording with auto-transcribe on and a transcription running, then Cmd-Q and confirm.
  Expected: one combined alert; the recording is stopped and saved (file plays), the transcription is cancelled, no new transcription starts for the saved file, and the app quits within about 12 seconds.

### Failure path

- [ ] `mv ~/.cache/diarize/voiceprint-<name>.npy ~/.cache/diarize/voiceprint-<name>.npy.bak`, then Transcribe a recording.
  Expected: a red error mentioning the missing voiceprint (and that passing 2+ recordings builds it), a collapsed "Pipeline output" disclosure with the last lines of the log, and a **Retry** button next to the guest-name field; not a hang or a raw stack trace alone. No transcript file is produced.
- [ ] **Rename it back:** `mv ~/.cache/diarize/voiceprint-<name>.npy.bak ~/.cache/diarize/voiceprint-<name>.npy`, then confirm with `ls ~/.cache/diarize/voiceprint-*`, and click **Retry**.
  Expected: the file is back under its original name and the transcription completes.
- [ ] Launch the app from Finder or `open build/MeetingRecorder.app` (not `swift run`) and Transcribe a recording.
  Expected: works without relying on your shell PATH (the app adds `/opt/homebrew/bin`), so `uv` and `ffmpeg` are found.

### Settings: transcription group

- [ ] Open Settings (gear icon). In the Transcription group change *Interviewer name*, *Default guest name* and the auto-transcribe toggle, click Done, quit and relaunch.
  Expected: the values persisted. The guest-name placeholder shows the new default guest name. (Restore the interviewer name before the next transcription: it selects the voiceprint file.)
- [ ] Pipeline folder: click **Choose…** and pick a folder without `run.sh` (e.g. `~/Documents`).
  Expected: an orange "No run.sh in the chosen pipeline folder." and "Using pipeline at ..." still names the bundled copy. Pick a folder with `run.sh` (e.g. the repo's `Pipeline/`): "Using pipeline at <that folder>". **Clear** goes back to the bundled copy.

## 6. Settings migration

- [ ] Before installing the new build, keep a copy of the old app's preferences (`defaults export <bundle id> ~/old-settings.plist`), or use a machine/profile that last ran the old version with a remote device and a mic set (e.g. remote `BlackHole 2ch` volume 0.7, mic `MacBook Air Microphone` volume 0.9). Launch the new build.
  Expected: the Audio Inputs list shows two inputs, remote first then mic, with those device names and gains; format and other old settings (output folder, ffmpeg path in Settings) are unchanged.
- [ ] Start and stop a short recording with the migrated settings.
  Expected: two meters, Saved, file plays.
- [ ] Corrupt one field only (e.g. set a bad value for the format key in the plist), relaunch.
  Expected: only that field falls back to its default; the inputs and other settings are kept (not a full reset).
- [ ] Click **Reset to defaults** under the Audio Inputs list (or delete the settings) and relaunch.
  Expected: the three default inputs return.

## 7. Wrap-up

- [ ] Restore everything you changed: voiceprint file name, input names/gains, ffmpeg override, auto-transcribe off, system output.
- [ ] Note any failures above with the app version/commit, then merge to `main` only when all boxes are ticked.
