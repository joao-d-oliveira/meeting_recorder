#!/usr/bin/env bash
# One-time setup of the transcription environment in ~/.cache/diarize/.venv.
# Apple Silicon only (mlx-whisper). Needs uv and ffmpeg (brew install uv ffmpeg).
# Versions are the ones the Saad/Khaled transcripts were produced with.
#
# The last step creates $VENV/.ready. run.sh treats a venv without that marker as unfinished
# (`uv venv` creates bin/python long before `uv pip install` has put anything in it), so an
# interrupted or failed install is completed by the next run instead of being mistaken for
# a working environment. Running this script again is safe: it resumes where it stopped.
set -euo pipefail
: "${HOME:?HOME is not set}"
# Apps launched from Finder get a minimal PATH; uv and ffmpeg live in Homebrew or ~/.local/bin.
for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin /usr/sbin /sbin; do
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$PATH:$d" ;;
  esac
done
export PATH
VENV="$HOME/.cache/diarize/.venv"
READY="$VENV/.ready"

# Cancellation (run.sh sends TERM): a foreground `uv` would keep running after this shell is
# gone and a trap would wait for it to finish, so each step runs in the background and the
# trap terminates it. TERM is repeated because a child between fork and exec swallows it.
on_signal() {
  trap '' INT TERM HUP
  local pids tries=0
  while pids="$(jobs -rp)"; [ -n "$pids" ]; do
    if [ "$tries" -lt 30 ]; then
      kill -TERM $pids 2>/dev/null || true
    else
      kill -KILL $pids 2>/dev/null || true
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  echo "Setup cancelled" >&2
  exit 130
}
trap on_signal INT TERM HUP

run_step() {
  local rc=0 pid
  "$@" &
  pid=$!
  wait "$pid" || rc=$?
  return "$rc"
}

command -v uv >/dev/null || { echo "uv not found: brew install uv" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found: brew install ffmpeg" >&2; exit 1; }
mkdir -p "$HOME/.cache/diarize"
rm -f "$READY"
# A directory without a working python is the remains of an interrupted `uv venv`; start over.
if [ -d "$VENV" ] && [ ! -x "$VENV/bin/python" ]; then rm -rf "$VENV"; fi
# An existing venv is completed, not recreated: `uv pip install` skips what is already there.
if [ ! -x "$VENV/bin/python" ]; then run_step uv venv "$VENV" --python 3.11; fi
run_step uv pip install --python "$VENV/bin/python" \
  mlx-whisper==0.4.3 speechbrain==1.1.2 torch==2.15.0 torchaudio==2.11.1 \
  scikit-learn==1.9.1 soundfile==0.14.0 numpy==2.4.6
: > "$READY"
echo "Environment ready: $VENV"
