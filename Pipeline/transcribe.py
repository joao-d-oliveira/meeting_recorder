"""Transcribe a 16 kHz WAV with mlx-whisper, keeping word timestamps.

Usage: python transcribe.py input.wav output.json
"""
import json
import sys

import mlx_whisper

src, dst = sys.argv[1], sys.argv[2]
result = mlx_whisper.transcribe(
    src,
    path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
    language="en",
    word_timestamps=True,
    condition_on_previous_text=False,  # reduces repetition loops on long audio
    verbose=False,
)
with open(dst, "w") as f:
    json.dump(result, f)
print(f"{dst}: {len(result['segments'])} segments")
