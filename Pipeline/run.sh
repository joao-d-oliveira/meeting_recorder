#!/usr/bin/env bash
# Audio -> speaker-labelled interview transcript.
#
# Usage:
#   run.sh OUT_DIR Guest:/path/to/audio.flac [Guest2:/path/to/audio2.flac ...]
#   run.sh --print-cache-key Guest:/path/to/audio.flac     (prints the cache key, nothing else)
#
# Env:
#   INTERVIEWER=Joao          name used for the interviewer's turns (default Joao)
#   REFRESH_VOICEPRINT=1      rebuild the interviewer voiceprint (needs 2+ recordings)
#
# Each recording is converted to 16 kHz mono and transcribed once; the whisper JSON is
# cached in ~/.cache/diarize so re-runs skip Whisper. The 16 kHz WAV (~115 MB per hour of
# audio) is cached only until the run that used it has diarized successfully, then deleted;
# a later run converts the audio again (seconds) and reuses the JSON.
# The cache key is unique per audio file (path + size + mtime), so recordings that
# share a basename (the app writes <timestamped folder>/meeting.flac) never collide.
# Writes OUT_DIR/<Guest>_Transcript.md and OUT_DIR/<Guest>_Transcript.summary.json.
#
# Machine-readable progress on stdout (the human messages stay):
#   STAGE: setup|convert|transcribe|diarize|done
#   PROGRESS: 0..100          (during the transcribe stage, when stdout is not a terminal)
#
# Vendored from the interview-transcribe skill; see README.md for the differences.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: run.sh OUT_DIR Guest:/path/to/audio.flac [Guest2:/path/to/audio2.flac ...]
Env:   INTERVIEWER=Joao  REFRESH_VOICEPRINT=1
EOF
}

die() { echo "$*" >&2; exit 1; }

: "${HOME:?HOME is not set}"

# Apps launched from Finder get a minimal PATH. Make sure the usual tool homes are
# searched (ffmpeg and uv live in Homebrew or ~/.local/bin; /usr/sbin has sysctl, which
# Python's joblib calls and otherwise warns about with a long traceback) without reordering
# whatever the caller already set.
for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin /usr/sbin /sbin; do
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$PATH:$d" ;;
  esac
done
export PATH
export PYTHONUNBUFFERED=1
export PYTHONUTF8=1
# Progress bars from model downloads are pure noise when nobody is watching a terminal.
if [ ! -t 2 ]; then export HF_HUB_DISABLE_PROGRESS_BARS=1; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HOME/.cache/diarize"
PY="$CACHE/.venv/bin/python"
# setup.sh creates this as its last step; see ensure_environment.
READY="$CACHE/.venv/.ready"

# Short hash of stdin, using whatever the system has (macOS ships shasum and md5).
short_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-12
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q | cut -c1-12
  else
    cksum | cut -d' ' -f1
  fi
}

# Lower-cases $1 the way Python's str.lower() does for the names that matter (diarize.py names
# the voiceprint file with it), without needing the venv. A Finder-launched app has no UTF-8
# locale, and tr in the C locale would leave "Élodie" as "Élodie"; hence the explicit one.
lower() {
  local out
  out="$(printf '%s' "$1" | LC_ALL=en_US.UTF-8 tr '[:upper:]' '[:lower:]' 2>/dev/null)" ||
    out="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$out"
}

# Cache key for a recording: <guest>-<basename>-<hash of absolute path|size|mtime>.
# Same file, same key (re-runs hit the cache); a different file or an edited file gets
# a new key. /usr/bin/stat is the BSD one even when GNU coreutils precede it in PATH.
cache_key() {
  local guest="$1" audio="$2" dir base abs st id slug
  dir="$(cd "$(dirname "$audio")" && pwd -P)"
  base="$(basename "$audio")"
  abs="$dir/$base"
  st="$(/usr/bin/stat -f '%z|%m' "$audio")"
  id="$(printf '%s|%s' "$abs" "$st" | short_hash)"
  slug="$(printf '%s-%s' "$guest" "${base%.*}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-')"
  printf '%s-%s' "$slug" "$id"
}

# Splits "Guest:/path" at the FIRST colon. Sets $guest and $audio.
parse_spec() {
  case "$1" in
    *:*) ;;
    *) die "Bad spec '$1': expected Guest:/path/to/audio" ;;
  esac
  guest="${1%%:*}"
  audio="${1#*:}"
  [ -n "$guest" ] || die "Bad spec '$1': the guest name is empty"
  case "$guest" in
    */*) die "Bad spec '$1': the guest name must not contain '/'" ;;
  esac
  [ -f "$audio" ] || die "Audio not found: $audio"
}

if [ "${1:-}" = "--print-cache-key" ]; then
  [ "$#" -eq 2 ] || { usage; exit 1; }
  parse_spec "$2"
  cache_key "$guest" "$audio"
  echo
  exit 0
fi

if [ "$#" -lt 2 ]; then
  usage; exit 1
fi


# --- cancellation -----------------------------------------------------------
# The app cancels by signalling this script. Foreground children would otherwise
# keep running (bash waits for them), so each step, setup included, runs in the background,
# and on INT/TERM/HUP every running job is terminated before exiting. The files this run is
# still writing (or only holds for itself) are removed so they can't be mistaken for finished
# cache entries next time. They carry this process's id, so a concurrent run on the same
# recording never writes to, renames or deletes them.
TEMP_FILES=()
cleanup_temp() {
  local f
  if [ "${#TEMP_FILES[@]}" -gt 0 ]; then
    for f in "${TEMP_FILES[@]}"; do rm -f "$f"; done
  fi
  TEMP_FILES=()
}
on_signal() {
  trap '' INT TERM HUP
  local pids tries=0
  # `jobs -rp` rather than a saved PID: it also covers a signal that lands right after the
  # fork. TERM is repeated because a child still between fork and exec swallows it.
  while pids="$(jobs -rp)"; [ -n "$pids" ]; do
    if [ "$tries" -lt 30 ]; then
      kill -TERM $pids 2>/dev/null || true
    else
      kill -KILL $pids 2>/dev/null || true
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  cleanup_temp
  echo "Cancelled" >&2
  exit 130
}
trap on_signal INT TERM HUP
trap cleanup_temp EXIT

run_step() {
  local rc=0 pid
  "$@" &
  pid=$!
  wait "$pid" || rc=$?
  return "$rc"
}
# -----------------------------------------------------------------------------

OUT="$1"; shift
INTERVIEWER="${INTERVIEWER:-Joao}"

# The name ends up in a file name (voiceprint-<name>.npy in the cache), so it must not be able
# to climb out of the cache folder or hide the file.
case "$INTERVIEWER" in
  .*|*/*|*\\*|*[[:cntrl:]]*)
    die "Invalid INTERVIEWER: the name must not start with '.' or contain '/', '\\' or control characters" ;;
esac
[ -n "${INTERVIEWER//[[:space:]]/}" ] || die "Invalid INTERVIEWER: the name is empty"

# Validate every spec before doing any slow work.
for spec in "$@"; do parse_spec "$spec"; done
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found: brew install ffmpeg"

# Fail fast: without a saved voiceprint (or with a refresh requested) the interviewer is
# found by comparing 2+ recordings. Discovering that after transcribing, or after downloading
# a few GB of Python packages, wastes minutes. This must not depend on the venv (lower() does not).
VOICEPRINT="$CACHE/voiceprint-$(lower "$INTERVIEWER").npy"
if { [ ! -f "$VOICEPRINT" ] || [ -n "${REFRESH_VOICEPRINT:-}" ]; } && [ "$#" -lt 2 ]; then
  die "No voiceprint at $VOICEPRINT and only one recording. Pass 2+ recordings that share the interviewer (this builds the voiceprint)."
fi

# setup.sh creates $READY as its final step. bin/python exists as soon as `uv venv` has run,
# long before the packages are installed, so it alone proves nothing: a cancelled or failed
# install would otherwise look like a working environment and fail later with
# ModuleNotFoundError. A venv with python but without the marker is either unfinished or
# complete but older than the marker (made by the skill's setup.sh, or by an earlier version of
# this script). An import of the real packages tells them apart (a few seconds, once: a
# complete venv gets the marker); an unfinished one goes through setup.sh again, which resumes.
IMPORT_CHECK='import mlx_whisper, speechbrain, sklearn, soundfile'
environment_ready() {
  [ -x "$PY" ] || return 1
  [ -f "$READY" ] && return 0
  echo "Checking the transcription environment"
  run_step "$PY" -c "$IMPORT_CHECK" >/dev/null 2>&1 || return 1
  : > "$READY" 2>/dev/null || true
}
if ! environment_ready; then
  echo "STAGE: setup"
  echo "Setting up the transcription environment (one-time; downloads a few GB)"
  run_step "$HERE/setup.sh" || die "Setup of the transcription environment failed"
fi

# Writes $2 (the cached WAV) from the audio $1 through a part file that is renamed into place
# only when ffmpeg succeeds.
convert_wav() {
  local part="$2.$$.part"
  TEMP_FILES+=("$part")
  run_step ffmpeg -nostdin -hide_banner -loglevel error -y -i "$1" -ac 1 -ar 16000 -f wav "$part"
  mv -f "$part" "$2"
}

# Sets $held to a hard link of the cached WAV $2 that only this run uses. A concurrent run on
# the same recording deletes the cached WAV when it finishes; without its own link this run
# could find the file gone between the cache check and diarize.py reading it. If the WAV has
# just disappeared it is converted again; where hard links don't work the cached file is used.
hold_wav() {
  held="${2%.wav}.$$.use.wav"
  TEMP_FILES+=("$held")
  ln -f "$2" "$held" 2>/dev/null && return 0
  if [ ! -f "$2" ]; then
    convert_wav "$1" "$2"
    ln -f "$2" "$held" 2>/dev/null && return 0
  fi
  held="$2"
}

mkdir -p "$CACHE" "$OUT"
# Temporary files that a run could not remove itself (SIGKILL, power loss) would stay forever
# under their per-process names. Nothing live is idle for a day.
find "$CACHE" -maxdepth 1 -type f \( -name '*.part' -o -name '*.use.wav' \) -mmin +1440 \
  -exec rm -f {} + 2>/dev/null || true

specs=()
wavs=()
for spec in "$@"; do
  parse_spec "$spec"
  key="$(cache_key "$guest" "$audio")"
  wav="$CACHE/$key.wav"
  json="$CACHE/$key.json"
  echo "STAGE: convert"
  if [ ! -f "$wav" ]; then
    echo "Converting $audio -> 16 kHz mono"
    convert_wav "$audio" "$wav"
  else
    echo "Using cached 16 kHz conversion"
  fi
  hold_wav "$audio" "$wav"
  echo "STAGE: transcribe"
  if [ ! -f "$json" ]; then
    echo "Transcribing $guest (whisper large-v3-turbo; roughly 1-2 min per 10 min of audio)"
    json_part="$json.$$.part"
    TEMP_FILES+=("$json_part")
    run_step "$PY" "$HERE/transcribe.py" "$held" "$json" "$json_part"
  else
    echo "Using cached transcription"
  fi
  wavs+=("$wav")
  specs+=("$guest:$held:$json")
done

echo "STAGE: diarize"
args=("$OUT" "${specs[@]}" --interviewer "$INTERVIEWER")
[ -n "${REFRESH_VOICEPRINT:-}" ] && args+=(--refresh-voiceprint)
run_step "$PY" "$HERE/diarize.py" "${args[@]}"
# Diarization succeeded (otherwise set -e has stopped the script). The WAVs are the bulk of
# the cache and only a retry after a failure needs them; the JSON stays, so a re-run skips Whisper.
for w in "${wavs[@]}"; do rm -f "$w"; done
echo "STAGE: done"
