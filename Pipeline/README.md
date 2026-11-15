# Pipeline

Audio file -> speaker-labelled transcript (`<Guest>_Transcript.md`) plus a machine-readable
`<Guest>_Transcript.summary.json`. Local only: Whisper (mlx-whisper, Apple Silicon) for the
words, SpeechBrain ECAPA voiceprints for who said them.

`Scripts/make_app.sh` copies this folder into `MeetingRecorder.app/Contents/Resources/Pipeline`
(without `tests/`); `TranscriptionController` runs `/bin/bash <dir>/run.sh`.

## Origin

Vendored from `~/.claude/skills/interview-transcribe/scripts/` (`run.sh`, `setup.sh`,
`transcribe.py`, `diarize.py`). The first commit of this folder is the unmodified copy, so
`git diff 8b79092 -- Pipeline` shows every change below. It stays CLI-compatible with the skill:

    run.sh OUT_DIR Guest:/path/audio.flac [Guest2:/path/audio2.flac ...]
    env INTERVIEWER=Joao  REFRESH_VOICEPRINT=1

and uses the same `~/.cache/diarize` (venv, ECAPA model, `voiceprint-<interviewer>.npy`), so
there is no second setup and no second voiceprint. The `.md` format is byte-identical to the
skill's (`tests/test_pipeline.py` checks this against the installed skill).

## Deliberate differences from the skill

`run.sh`
- **Cache key is unique per file.** The skill keyed the cached 16 kHz WAV and Whisper JSON on
  `guest + audio basename`. The app names every recording `<timestamped folder>/meeting.flac`, so
  a second recording would silently reuse the first one's transcript. The key is now
  `<guest>-<basename>-<12 hex of sha256(absolute path | size | mtime)>`. The same file hits the
  cache on a re-run; a different path, or a file that changed, does not. Entries cached by the
  skill under the old key are simply not reused. `run.sh --print-cache-key Guest:/path` prints
  the key (used by the tests).
- **Progress lines on stdout**, next to the human messages: `STAGE: setup|convert|transcribe|
  diarize|done` (`setup` only when the environment has to be created) and, while transcribing,
  `PROGRESS: 0..100`.
- **Cancellable.** Each step runs in the background and `run.sh` traps INT/TERM/HUP, forwards
  TERM to the running step, deletes the partial cache file and exits 130. (Foreground children
  would otherwise keep running after the script was signalled.)
- **No half-written cache files.** The WAV is written to `<key>.wav.part` and renamed when
  ffmpeg succeeds; `transcribe.py` does the same for the JSON. The skill would reuse a
  truncated file after an interrupted run.
- **Fails fast.** Audio missing, malformed `Guest:path` specs, a guest name with `/`, no
  `ffmpeg`, and "no voiceprint and only one recording" are all reported before the slow work
  starts (the skill found out about the voiceprint only after transcribing).
- **Finder-safe environment.** No reliance on the shell profile. `/opt/homebrew/bin`,
  `/usr/local/bin`, `~/.local/bin` (uv), `/usr/sbin` and `/sbin` are appended to `PATH` if
  missing (`/usr/sbin` has `sysctl`, which joblib calls; without it every run prints a long
  traceback). `PYTHONUNBUFFERED=1` and `PYTHONUTF8=1` are set; huggingface progress bars are
  disabled when stderr is not a terminal.
- `ffmpeg` gets `-nostdin` and an explicit `-f wav`.

`setup.sh`
- Same `PATH` additions, so `uv` is found at `~/.local/bin/uv` from a Finder-launched app.

`transcribe.py`
- Prints `PROGRESS: <n>` lines by routing mlx_whisper's tqdm bar through a small subclass
  (only mlx_whisper's own reference is swapped, no global patching). Printed when stdout is not
  a terminal or `PIPELINE_PROGRESS=1`; in a terminal the normal tqdm bar is shown instead. If
  mlx_whisper's internals ever differ, the hook logs one line to stderr and progress stays
  indeterminate; transcription is unaffected.
- Atomic write of the JSON (see above). The work moved into `main()` so the hook is testable.

`diarize.py`
- Writes `<Guest>_Transcript.summary.json` next to the `.md` (schema below).
- A recording with fewer than 2 speech windows exits with "not enough speech to tell voices
  apart" instead of a scikit-learn traceback.
- The `(?)` rule and the weak-match rule are the skill's, factored into `uncertain()` and the
  `weak` flag so the `.md` and the summary cannot disagree.

## summary.json (version 1)

| key | meaning |
| --- | --- |
| `version` | 1 |
| `transcript_path` | absolute path of the `.md` |
| `guest`, `interviewer` | names used in the transcript |
| `turn_count`, `word_count` | |
| `duration_seconds` | end of the last word |
| `interviewer_speaking_seconds`, `guest_speaking_seconds` | sum of that speaker's turn lengths |
| `identification_method` | `voiceprint` (saved voiceprint) or `cross-file` (2+ recordings) |
| `identification` | human string, e.g. `voiceprint similarity [0.128 0.926]` |
| `interviewer_cluster` | index (0/1) of the voice cluster judged to be the interviewer |
| `similarity_scores` | `[cluster0, cluster1]` similarity numbers |
| `interviewer_similarity`, `guest_similarity` | the same scores by role |
| `weak_match` | the skill's `WARNING` rule: best score < 0.5 or the two differ by < 0.2 (voiceprint only; always false for `cross-file`) |
| `uncertain_turns` | number of turns marked `(?)` in the `.md` |

## Checks

    ~/.cache/diarize/.venv/bin/python -I Pipeline/tests/test_pipeline.py

Model-free: summary fields, weak-match rule, `.md` byte-identical to the skill's `diarize.py`,
progress hook. The Swift tests (`swift run RecorderCoreTests`) additionally run
`run.sh --print-cache-key` for the cache-key behaviour.
