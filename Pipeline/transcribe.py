"""Transcribe a 16 kHz WAV with mlx-whisper, keeping word timestamps.

Usage: python transcribe.py input.wav output.json

While transcribing, prints `PROGRESS: <0-100>` lines on stdout whenever the integer
percentage changes. They are printed when stdout is not a terminal (or when
PIPELINE_PROGRESS=1), so a parent process can show a progress bar; in a terminal
the usual tqdm bar on stderr is shown instead.
"""
import json
import os
import sys
import types

EMIT_PROGRESS = os.environ.get("PIPELINE_PROGRESS") == "1" or not sys.stdout.isatty()
_last_pct = -1


def emit_progress(pct):
    """Print `PROGRESS: <pct>` when the integer percentage changed."""
    global _last_pct
    pct = max(0, min(100, int(pct)))
    if EMIT_PROGRESS and pct != _last_pct:
        _last_pct = pct
        print(f"PROGRESS: {pct}", flush=True)


def install_progress_hook():
    """Route mlx_whisper's tqdm bar through a subclass that reports progress.

    mlx_whisper.transcribe does `import tqdm` and calls `tqdm.tqdm(total=frames, ...)`;
    swap its module-level reference for a shim so no other tqdm user is affected.
    Never fatal: if mlx_whisper's internals differ, progress is simply not reported.
    """
    try:
        import tqdm

        module = sys.modules["mlx_whisper.transcribe"]
        show_bar = sys.stderr.isatty()
        base = tqdm.tqdm

        class ProgressBar(base):
            def __init__(self, *args, **kwargs):
                kwargs["disable"] = kwargs.get("disable", False) or not show_bar
                super().__init__(*args, **kwargs)
                self._seen = 0

            def update(self, n=1):
                self._seen += n
                if self.total:
                    emit_progress(100 * self._seen / self.total)
                return super().update(n)

        module.tqdm = types.SimpleNamespace(tqdm=ProgressBar)
    except Exception as e:  # noqa: BLE001 - progress is best-effort
        print(f"progress hook unavailable: {e}", file=sys.stderr)


def main():
    import mlx_whisper  # imported before the hook so mlx_whisper.transcribe is loaded

    src, dst = sys.argv[1], sys.argv[2]
    install_progress_hook()
    result = mlx_whisper.transcribe(
        src,
        path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
        language="en",
        word_timestamps=True,
        condition_on_previous_text=False,  # reduces repetition loops on long audio
        verbose=False,
    )
    # Write to a temp file and rename, so an interrupted run never leaves a truncated
    # JSON that a later run would take for a finished transcription.
    tmp = dst + ".part"
    with open(tmp, "w") as f:
        json.dump(result, f)
    os.replace(tmp, dst)
    emit_progress(100)
    print(f"{dst}: {len(result['segments'])} segments")


if __name__ == "__main__":
    main()
