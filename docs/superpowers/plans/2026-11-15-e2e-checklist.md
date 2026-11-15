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
- [ ] **Defaults.** Open Settings (fresh settings, or reset the inputs).
  Expected: three inputs in order: WF-1000XM6 (gain 0.55, skip if missing), BlackHole 2ch (0.55), MacBook Air Microphone (1.00). ffmpeg detected at `/opt/homebrew/bin/ffmpeg`.

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
- [ ] Temporarily rename the BlackHole input in Settings to a nonexistent name (e.g. `BlackHole 99ch`), or uninstall/disable it, then Start.
  Expected: Start is blocked; the message names the missing device; no recording is created. Restore the name afterwards.
- [ ] Set every input to a nonexistent name with skip-if-missing on.
  Expected: blocked, with an error that nothing is left to record. Restore the defaults afterwards.
- [ ] Remove all inputs (or blank a device name).
  Expected: blocked with a message ("at least one input" / "device name required"). Restore the defaults afterwards.
- [ ] Settings > ffmpeg path override = `/nonexistent/ffmpeg`, Start.
  Expected: error says ffmpeg was not found and how to install it. Clear the override; "Using ffmpeg at /opt/homebrew/bin/ffmpeg" reappears.

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

Prerequisite: a voiceprint exists at `~/.cache/diarize/voiceprint-<name>.npy` (`<name>` = interviewer name in Settings; `ls ~/.cache/diarize/`). Use a real recording with a clear interviewer/guest exchange (at least a few minutes), ideally one recorded in section 1.

- [ ] Open the saved recording in the app, enter a guest name (e.g. `TestGuest`), click Transcribe.
  Expected: progress appears with stage names changing over time (convert, transcribe, diarize, ...); the Transcribe button is disabled or turns into Cancel. First run only: models download and it takes noticeably longer.
- [ ] Wait for completion.
  Expected: a summary appears with: number of turns, duration, speaking time per speaker (Interviewer / Interviewee, adding up to roughly the duration), the identification method, and the voiceprint scores. Time taken is roughly 1-2 min per 10 min of audio.
- [ ] Check the scores.
  Expected: interviewer cluster scores about 0.9+ and the other cluster well under 0.5. No weak-match warning for a good recording.
- [ ] Check the `(?)` count against the file: `grep -c '(?)' <Guest>_Transcript.md`.
  Expected: the number matches the summary (low for a clean recording).
- [ ] Files next to the recording: `ls "$(dirname "$(ls -t ~/Documents/Recordings/meetings/*/meeting.flac | head -1)")"`
  Expected: `TestGuest_Transcript.md` and `TestGuest_Transcript.summary.json` sit beside `meeting.flac` (not in `~/Recordings` or elsewhere). The JSON has turns, duration, speaking seconds per label, identification, weak-match flag.
- [ ] Click Open transcript, and Show in Finder.
  Expected: the transcript opens in the default app; Finder highlights the recording folder or transcript.
- [ ] Read the first ~10 turns and the last 3-4 in the transcript.
  Expected: the interviewer opens, asks the questions and closes; the guest answers. Labels read `<Interviewer> (Interviewer)` and `TestGuest (Interviewee)`, with timestamps. Wrong labels, missing turns, or text out of order are failures. Known quirks that are not failures: words at a speaker change landing in the neighbouring turn, misheard short phrases, misspelled proper names.
- [ ] Weak match: transcribe a recording where the interviewer's voice is absent or very quiet (e.g. only the BlackHole input has speech, or a recording of two other people).
  Expected: a weak-match warning is shown in the summary and a low score; some turns may be marked `(?)`.
- [ ] Two recordings, same guest name: transcribe a second, different recording with the same guest name.
  Expected: the second transcript is for the second recording (different content/timestamps), not a stale copy of the first.
- [ ] Auto-transcribe: enable it in Settings, record 20-30 s, stop.
  Expected: transcription starts on its own after Saved, using the default guest name when none was entered. Disable it again afterwards.

### Cancel

- [ ] Start a transcription of a longer recording (5+ minutes), and click Cancel during the transcribe stage.
  Expected: it stops within a few seconds, status shows cancelled (not an error), no transcript/summary file is left half-written, and `pgrep -fl "mlx_whisper|diarize|run.sh"` shows no leftover processes. The Transcribe button works again, and a re-run completes.

### Failure path

- [ ] `mv ~/.cache/diarize/voiceprint-<name>.npy ~/.cache/diarize/voiceprint-<name>.npy.bak`, then Transcribe a recording.
  Expected: it fails with a clear error mentioning the missing voiceprint (and that the interview-transcribe skill creates it), not a hang or a raw stack trace alone. No transcript file is produced.
- [ ] **Rename it back:** `mv ~/.cache/diarize/voiceprint-<name>.npy.bak ~/.cache/diarize/voiceprint-<name>.npy`, then confirm with `ls ~/.cache/diarize/voiceprint-*`.
  Expected: the file is back under its original name. Transcribe again to confirm it works.
- [ ] Launch the app from Finder or `open build/MeetingRecorder.app` (not `swift run`) and Transcribe a recording.
  Expected: works without relying on your shell PATH (the app adds `/opt/homebrew/bin`), so `uv` and `ffmpeg` are found.

## 6. Settings migration

- [ ] Before installing the new build, keep a copy of the old app's preferences (`defaults export <bundle id> ~/old-settings.plist`), or use a machine/profile that last ran the old version with a remote device and a mic set (e.g. remote `BlackHole 2ch` volume 0.7, mic `MacBook Air Microphone` volume 0.9). Launch the new build.
  Expected: Settings shows two inputs, remote first then mic, with those device names and volumes; format and other old settings (output folder, ffmpeg path) are unchanged.
- [ ] Start and stop a short recording with the migrated settings.
  Expected: two meters, Saved, file plays.
- [ ] Corrupt one field only (e.g. set a bad value for the format key in the plist), relaunch.
  Expected: only that field falls back to its default; the inputs and other settings are kept (not a full reset).
- [ ] Reset the inputs to defaults (or delete the settings) and relaunch.
  Expected: the three default inputs return.

## 7. Wrap-up

- [ ] Restore everything you changed: voiceprint file name, input names/gains, ffmpeg override, auto-transcribe off, system output.
- [ ] Note any failures above with the app version/commit, then merge to `main` only when all boxes are ticked.
