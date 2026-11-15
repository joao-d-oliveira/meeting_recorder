# Pipeline

Audio file -> speaker-labelled transcript (`<Guest>_Transcript.md`) plus a machine-readable
`<Guest>_Transcript.summary.json`. Local only: Whisper (mlx-whisper, Apple Silicon) for the
words, SpeechBrain ECAPA voiceprints for who said them.

`Scripts/make_app.sh` copies this folder into `MeetingRecorder.app/Contents/Resources/Pipeline`
(without `tests/`); `TranscriptionController` runs `/bin/bash <dir>/run.sh`.

## Origin

Vendored from `~/.claude/skills/interview-transcribe/scripts/` (`run.sh`, `setup.sh`,
`transcribe.py`, `diarize.py`). The first commit of this folder is the unmodified copy, so
diffing the files against that commit shows every change below. It stays CLI-compatible with the skill:

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
  skill under the old key are simply not reused (and not cleaned up either; their `.wav` files
  can be deleted by hand). `run.sh --print-cache-key Guest:/path` prints the key (used by the
  tests).
- **The cached WAV is temporary.** A 16 kHz WAV is about 115 MB per hour of audio, and with a
  key per file the cache would grow without bound. After a successful diarization `run.sh`
  deletes the WAV it used; the Whisper JSON (small) stays, so a re-run skips Whisper and only
  converts the audio again (seconds). When a run fails or is cancelled the WAV is kept, so the
  retry skips the conversion too. Temporary files that a killed run could not remove itself
  (`*.part`, `*.use.wav`) are deleted once they are more than a day old.
- **Progress lines on stdout**, next to the human messages: `STAGE: setup|convert|transcribe|
  diarize|done` (`setup` only when the environment has to be created) and, while transcribing,
  `PROGRESS: 0..100`.
- **Cancellable, setup included.** Each step, `setup.sh` too, runs in the background and
  `run.sh` traps INT/TERM/HUP, forwards TERM to the running step, deletes the temporary files
  of this run and exits 130. (Foreground children would otherwise keep running after the script
  was signalled, and a signal arriving during setup was not acted on until `setup.sh` ended.)
  `setup.sh` stops its own `uv` the same way.
- **No half-written cache files.** The WAV is written to `<key>.wav.<pid>.part` and renamed when
  ffmpeg succeeds; `transcribe.py` does the same for the JSON (`<key>.json.<pid>.part`, passed
  to it as a third argument). The skill would reuse a truncated file after an interrupted run.
- **Runs on the same recording can overlap.** The part files carry the run's process id, so one
  run's rename can't fail because the other already took the file, and a cancel only removes
  its own files. Because a finishing run deletes the cached WAV (above), each run hard-links the
  WAV as `<key>.<pid>.use.wav` and gives that to `transcribe.py` and `diarize.py`; the other
  run's delete can't pull it away.
- **An unfinished environment is not mistaken for a ready one.** `uv venv` creates
  `~/.cache/diarize/.venv/bin/python` long before `uv pip install` has put any package in it, so
  a cancelled or failed install used to look like a working environment and failed later with
  `ModuleNotFoundError`. `setup.sh` now creates `.venv/.ready` as its last step and `run.sh`
  runs setup again unless python and the marker both exist. A venv that has python but no marker
  (made by the skill's `setup.sh`, or before this change) is accepted if
  `python -c 'import mlx_whisper, speechbrain, sklearn, soundfile'` succeeds (a few seconds,
  once) and then gets the marker, so an existing complete environment is not reinstalled.
- **`INTERVIEWER` is validated.** It becomes part of a file name (`voiceprint-<name>.npy`), so a
  name that is only whitespace, starts with `.`, or contains `/`, `\` or a control character
  (newline, tab, ...) is rejected before any work. (`INTERVIEWER=` set but empty still means
  the default `Joao`, as in the skill.) `diarize.py` additionally refuses a default voiceprint
  path that is not directly inside the cache folder (see below).
- **Fails fast.** Audio missing, malformed `Guest:path` specs, a guest name with `/`, a bad
  `INTERVIEWER`, no `ffmpeg`, and "no voiceprint and only one recording" are all reported before
  the slow work starts (the skill found out about the voiceprint only after transcribing). The
  voiceprint check runs before setup and without the venv (the name is lower-cased with `tr`,
  in a UTF-8 locale so that `Élodie` gives the same file name as Python's `str.lower()`), so a
  first run without a voiceprint no longer downloads gigabytes before failing.
- **Finder-safe environment.** No reliance on the shell profile. `~/.local/bin` (uv),
  `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/sbin` and `/sbin` are appended to `PATH` if
  missing (`/usr/sbin` has `sysctl`, which joblib calls; without it every run prints a long
  traceback). `PYTHONUNBUFFERED=1` and `PYTHONUTF8=1` are set; huggingface progress bars are
  disabled when stderr is not a terminal.
- `ffmpeg` gets `-nostdin` and an explicit `-f wav`.

`setup.sh`
- Same `PATH` additions, so `uv` is found at `~/.local/bin/uv` from a Finder-launched app.
- Creates `.venv/.ready` as its final step (see above), and can be run again after an
  interruption: an existing venv with python is completed by `uv pip install` instead of being
  recreated, and a `.venv` folder without a python (an interrupted `uv venv`) is removed first.
- `uv` runs in the background and TERM stops it, so cancelling during the multi-GB install
  returns at once instead of leaving `uv` running.

`transcribe.py`
- Prints `PROGRESS: <n>` lines by routing mlx_whisper's tqdm bar through a small subclass
  (only mlx_whisper's own reference is swapped, no global patching). Printed when stdout is not
  a terminal or `PIPELINE_PROGRESS=1`; in a terminal the normal tqdm bar is shown instead. If
  mlx_whisper's internals ever differ, the hook logs one line to stderr and progress stays
  indeterminate; transcription is unaffected.
- Atomic write of the JSON (see above), through an optional third argument
  (`transcribe.py in.wav out.json [part.json]`; the default is `out.json.part`, as before). The
  work moved into `main()` so the hook is testable.

`diarize.py`
- Writes `<Guest>_Transcript.summary.json` next to the `.md` (schema below).
- A recording with fewer than 2 speech windows exits with "not enough speech to tell voices
  apart" instead of a scikit-learn traceback.
- The default voiceprint path (`~/.cache/diarize/voiceprint-<interviewer>.npy`) must be directly
  inside the cache folder: an interviewer name such as `x/../../evil` is refused before anything
  is read or written, where the skill would have saved the voiceprint outside the cache. A path
  given with `--voiceprint` is the caller's own choice and is not checked.
- The `(?)` rule and the weak-match rule are the skill's, factored into `uncertain()` and the
  `weak` flag so the `.md` and the summary cannot disagree.

## How the app drives it

`TranscriptionController` passes one recording, which can only be matched against a saved
voiceprint, and never sets `REFRESH_VOICEPRINT`. So before launching `run.sh` it checks that
`~/.cache/diarize/voiceprint-<interviewer, lower-cased>.npy` exists and otherwise fails at once
with instructions to create it with the skill from two or more recordings (a pipeline folder
chosen in Settings is not checked: it may be a different implementation). Where the transcript
is written is decided by `TranscriptionRequest.defaultOutputDirectory(for:)`: the recording's
own folder, or `<audio name> transcript/` next to it when other audio files share that folder.

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
where the default voiceprint path may be written (never from one recording, never outside the
cache folder; the tests point `diarize.CACHE` at a temp folder), progress hook, `transcribe.py`'s
part-file argument. Run it with `-B` so no `__pycache__` appears in the repo. The Swift tests
(`swift run RecorderCoreTests`) run `run.sh` and `setup.sh` themselves against stub `uv`,
`ffmpeg` and Python in a throwaway `HOME`: cache keys, stages, cancelling during setup, convert
and transcribe, the `.ready` marker, overlapping runs, `INTERVIEWER` validation, and what is
left in the cache afterwards.
