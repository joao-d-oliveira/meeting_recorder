#!/usr/bin/env bash
# Audio -> speaker-labelled interview transcript.
#
# Usage:
#   run.sh OUT_DIR Guest:/path/to/audio.flac [Guest2:/path/to/audio2.flac ...]
#
# Env:
#   INTERVIEWER=Joao          name used for the interviewer's turns (default Joao)
#   REFRESH_VOICEPRINT=1      rebuild the interviewer voiceprint (needs 2+ recordings)
#
# Each recording is converted to 16 kHz mono and transcribed once; the WAV and
# whisper JSON are cached in ~/.cache/diarize so re-runs only redo diarization.
# Writes OUT_DIR/<Guest>_Transcript.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HOME/.cache/diarize"
PY="$CACHE/.venv/bin/python"

if [ "$#" -lt 2 ]; then
  sed -n '2,13p' "$0"; exit 1
fi
[ -x "$PY" ] || "$HERE/setup.sh"

OUT="$1"; shift
mkdir -p "$CACHE" "$OUT"
specs=()
for spec in "$@"; do
  guest="${spec%%:*}"
  audio="${spec#*:}"
  [ -f "$audio" ] || { echo "Audio not found: $audio" >&2; exit 1; }
  base="$(basename "${audio%.*}")"
  key="$(printf '%s-%s' "$guest" "$base" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-')"
  wav="$CACHE/$key.wav"
  json="$CACHE/$key.json"
  if [ ! -f "$wav" ]; then
    echo "Converting $audio -> 16 kHz mono"
    ffmpeg -hide_banner -loglevel error -y -i "$audio" -ac 1 -ar 16000 "$wav"
  fi
  if [ ! -f "$json" ]; then
    echo "Transcribing $guest (whisper large-v3-turbo; roughly 1-2 min per 10 min of audio)"
    "$PY" "$HERE/transcribe.py" "$wav" "$json"
  fi
  specs+=("$guest:$wav:$json")
done

args=("$OUT" "${specs[@]}" --interviewer "${INTERVIEWER:-Joao}")
[ -n "${REFRESH_VOICEPRINT:-}" ] && args+=(--refresh-voiceprint)
"$PY" "$HERE/diarize.py" "${args[@]}"
