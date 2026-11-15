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
# Each recording is converted to 16 kHz mono and transcribed once; the WAV and
# whisper JSON are cached in ~/.cache/diarize so re-runs only redo diarization.
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
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" /usr/sbin /sbin; do
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
# keep running (bash waits for them), so run each step in the background, wait on
# it, and forward the signal. Partial cache files are removed so they can't be
# mistaken for finished ones next time.
CHILD_PID=""
PARTIAL=""
cleanup_partial() {
  if [ -n "$PARTIAL" ]; then rm -f "$PARTIAL"; fi
  PARTIAL=""
}
on_signal() {
  trap '' INT TERM HUP
  if [ -n "$CHILD_PID" ]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  cleanup_partial
  echo "Cancelled" >&2
  exit 130
}
trap on_signal INT TERM HUP
trap cleanup_partial EXIT

run_step() {
  local rc=0
  "$@" &
  CHILD_PID=$!
  wait "$CHILD_PID" || rc=$?
  CHILD_PID=""
  return "$rc"
}
# -----------------------------------------------------------------------------

OUT="$1"; shift
INTERVIEWER="${INTERVIEWER:-Joao}"

# Validate every spec before doing any slow work.
for spec in "$@"; do parse_spec "$spec"; done

if [ ! -x "$PY" ]; then
  echo "STAGE: setup"
  echo "Setting up the transcription environment (one-time; downloads a few GB)"
  "$HERE/setup.sh" || die "Setup of the transcription environment failed"
fi
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found: brew install ffmpeg"

# Fail fast: without a saved voiceprint (or with a refresh requested) the interviewer is
# found by comparing 2+ recordings. Discovering that after transcribing wastes minutes.
vp_name="$("$PY" -c 'import sys; print(sys.argv[1].lower())' "$INTERVIEWER")"
VOICEPRINT="$CACHE/voiceprint-$vp_name.npy"
if { [ ! -f "$VOICEPRINT" ] || [ -n "${REFRESH_VOICEPRINT:-}" ]; } && [ "$#" -lt 2 ]; then
  die "No voiceprint at $VOICEPRINT and only one recording. Pass 2+ recordings that share the interviewer (this builds the voiceprint)."
fi

mkdir -p "$CACHE" "$OUT"
specs=()
for spec in "$@"; do
  parse_spec "$spec"
  key="$(cache_key "$guest" "$audio")"
  wav="$CACHE/$key.wav"
  json="$CACHE/$key.json"
  echo "STAGE: convert"
  if [ ! -f "$wav" ]; then
    echo "Converting $audio -> 16 kHz mono"
    PARTIAL="$wav.part"
    run_step ffmpeg -nostdin -hide_banner -loglevel error -y -i "$audio" -ac 1 -ar 16000 -f wav "$wav.part"
    mv -f "$wav.part" "$wav"
    PARTIAL=""
  else
    echo "Using cached 16 kHz conversion"
  fi
  echo "STAGE: transcribe"
  if [ ! -f "$json" ]; then
    echo "Transcribing $guest (whisper large-v3-turbo; roughly 1-2 min per 10 min of audio)"
    PARTIAL="$json.part"
    run_step "$PY" "$HERE/transcribe.py" "$wav" "$json"
    PARTIAL=""
  else
    echo "Using cached transcription"
  fi
  specs+=("$guest:$wav:$json")
done

echo "STAGE: diarize"
args=("$OUT" "${specs[@]}" --interviewer "$INTERVIEWER")
[ -n "${REFRESH_VOICEPRINT:-}" ] && args+=(--refresh-voiceprint)
run_step "$PY" "$HERE/diarize.py" "${args[@]}"
echo "STAGE: done"
