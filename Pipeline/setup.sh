#!/usr/bin/env bash
# One-time setup of the transcription environment in ~/.cache/diarize/.venv.
# Apple Silicon only (mlx-whisper). Needs uv and ffmpeg (brew install uv ffmpeg).
# Versions are the ones the Saad/Khaled transcripts were produced with.
set -euo pipefail
: "${HOME:?HOME is not set}"
# Apps launched from Finder get a minimal PATH; uv and ffmpeg live in Homebrew or ~/.local/bin.
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" /usr/sbin /sbin; do
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$PATH:$d" ;;
  esac
done
export PATH
VENV="$HOME/.cache/diarize/.venv"
command -v uv >/dev/null || { echo "uv not found: brew install uv" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found: brew install ffmpeg" >&2; exit 1; }
mkdir -p "$HOME/.cache/diarize"
uv venv "$VENV" --python 3.11
uv pip install --python "$VENV/bin/python" \
  mlx-whisper==0.4.3 speechbrain==1.1.2 torch==2.15.0 torchaudio==2.11.1 \
  scikit-learn==1.9.1 soundfile==0.14.0 numpy==2.4.6
echo "Environment ready: $VENV"
