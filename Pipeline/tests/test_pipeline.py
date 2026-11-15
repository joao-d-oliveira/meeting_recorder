"""Model-free checks for the vendored pipeline.

Run with the pipeline's own interpreter (it has numpy/torch/speechbrain installed):

    ~/.cache/diarize/.venv/bin/python -I Pipeline/tests/test_pipeline.py

Covers: the summary.json writer, that the .md output is byte-identical to the original
skill's diarize.py for the same input, and the transcribe.py progress hook. Uses fabricated
data and a temp directory only; no model is loaded and nothing is written to the
user's cache.
"""
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path

import numpy as np

PIPELINE = Path(__file__).resolve().parent.parent
SKILL_DIARIZE = Path.home() / ".claude/skills/interview-transcribe/scripts/diarize.py"
sys.path.insert(0, str(PIPELINE))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fabricated_recording():
    """30 words, 3 turns: speaker 0, speaker 1, speaker 0. The middle turn is low-margin."""
    words, labels, margins = [], [], []
    t = 0.0
    for i in range(30):
        words.append({"start": t, "end": t + 0.4, "text": f" w{i}"})
        labels.append(0 if i < 10 or i >= 20 else 1)
        margins.append(0.01 if 10 <= i < 20 else 0.4)
        t += 0.5
    cents = np.zeros((2, 8), dtype=np.float32)
    cents[0, 0] = 1.0
    cents[1, 1] = 1.0
    return {"guest": "Fab", "words": words, "labels": labels, "margins": margins, "cents": cents}


def run_main(module, out_dir, voiceprint_path, interviewer="Joao"):
    """Runs module.main() on the fabricated recording, bypassing audio and models."""
    module.process = lambda guest, wav, words_json: fabricated_recording()
    argv = sys.argv
    sys.argv = ["diarize.py", str(out_dir), "Fab:x.wav:x.json", "--interviewer", interviewer,
                "--voiceprint", str(voiceprint_path)]
    try:
        with contextlib.redirect_stdout(io.StringIO()) as out:
            module.main()
    finally:
        sys.argv = argv
    return out.getvalue()


class SummaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.diarize = load("vendored_diarize", PIPELINE / "diarize.py")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        # Voiceprint equal to cluster 1, so cluster 1 is the interviewer (score [0, 1]).
        self.vp = self.dir / "voiceprint-joao.npy"
        np.save(self.vp, fabricated_recording()["cents"][1])

    def tearDown(self):
        self.tmp.cleanup()

    def test_summary_fields(self):
        out = run_main(self.diarize, self.dir / "out", self.vp)
        summary = json.loads((self.dir / "out/Fab_Transcript.summary.json").read_text())
        self.assertEqual(summary["version"], 1)
        self.assertEqual(Path(summary["transcript_path"]), (self.dir / "out/Fab_Transcript.md").absolute())
        self.assertEqual(summary["guest"], "Fab")
        self.assertEqual(summary["interviewer"], "Joao")
        self.assertEqual(summary["turn_count"], 3)
        self.assertEqual(summary["word_count"], 30)
        self.assertAlmostEqual(summary["duration_seconds"], 14.9, places=2)  # last word ends at 29*0.5+0.4
        # Turns: [0, 4.9] spk0, [5.0, 9.9] spk1, [10.0, 14.9] spk0. Interviewer is cluster 1.
        self.assertEqual(summary["interviewer_cluster"], 1)
        self.assertAlmostEqual(summary["interviewer_speaking_seconds"], 4.9, places=2)
        self.assertAlmostEqual(summary["guest_speaking_seconds"], 9.8, places=2)
        self.assertEqual(summary["identification_method"], "voiceprint")
        self.assertIn("voiceprint similarity", summary["identification"])
        self.assertEqual(summary["similarity_scores"], [0.0, 1.0])
        self.assertEqual(summary["interviewer_similarity"], 1.0)
        self.assertEqual(summary["guest_similarity"], 0.0)
        self.assertFalse(summary["weak_match"])
        self.assertEqual(summary["uncertain_turns"], 1)
        self.assertIn("wrote", out)

    def test_weak_match_follows_the_original_rule(self):
        # Voiceprint halfway between the clusters: both scores ~0.707, margin 0 -> weak.
        halfway = np.array([1, 1, 0, 0, 0, 0, 0, 0], dtype=np.float32)
        np.save(self.vp, halfway / np.linalg.norm(halfway))
        out = run_main(self.diarize, self.dir / "out", self.vp)
        summary = json.loads((self.dir / "out/Fab_Transcript.summary.json").read_text())
        self.assertTrue(summary["weak_match"])
        self.assertIn("WARNING Fab: weak voiceprint match", out)

    def test_strong_match_is_not_weak(self):
        out = run_main(self.diarize, self.dir / "out", self.vp)
        summary = json.loads((self.dir / "out/Fab_Transcript.summary.json").read_text())
        self.assertFalse(summary["weak_match"])
        self.assertNotIn("WARNING", out)

    @unittest.skipUnless(SKILL_DIARIZE.exists(), "original skill diarize.py not installed")
    def test_markdown_is_byte_identical_to_the_original(self):
        original = load("skill_diarize", SKILL_DIARIZE)
        run_main(original, self.dir / "orig", self.vp)
        run_main(self.diarize, self.dir / "new", self.vp)
        a = (self.dir / "orig/Fab_Transcript.md").read_bytes()
        b = (self.dir / "new/Fab_Transcript.md").read_bytes()
        self.assertEqual(a, b)
        self.assertFalse((self.dir / "orig/Fab_Transcript.summary.json").exists())

    def test_no_leftover_temp_files(self):
        run_main(self.diarize, self.dir / "out", self.vp)
        self.assertEqual(sorted(p.name for p in (self.dir / "out").iterdir()),
                         ["Fab_Transcript.md", "Fab_Transcript.summary.json"])


class ProgressHookTests(unittest.TestCase):
    def test_hook_emits_percent_lines_and_leaves_tqdm_alone(self):
        import tqdm
        transcribe = load("vendored_transcribe", PIPELINE / "transcribe.py")
        transcribe.EMIT_PROGRESS = True
        transcribe._last_pct = -1
        fake = types.ModuleType("mlx_whisper.transcribe")
        fake.tqdm = tqdm
        sys.modules["mlx_whisper.transcribe"] = fake
        try:
            transcribe.install_progress_hook()
            self.assertIsNot(fake.tqdm.tqdm, tqdm.tqdm)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                with fake.tqdm.tqdm(total=200, unit="frames", disable=False) as bar:
                    bar.update(50)
                    bar.update(1)   # 25% again: deduplicated
                    bar.update(49)
                    bar.update(100)
        finally:
            del sys.modules["mlx_whisper.transcribe"]
        self.assertEqual(buf.getvalue().splitlines(),
                         ["PROGRESS: 25", "PROGRESS: 50", "PROGRESS: 100"])

    def test_hook_is_silent_when_not_emitting(self):
        import tqdm
        transcribe = load("vendored_transcribe2", PIPELINE / "transcribe.py")
        transcribe.EMIT_PROGRESS = False
        fake = types.ModuleType("mlx_whisper.transcribe")
        fake.tqdm = tqdm
        sys.modules["mlx_whisper.transcribe"] = fake
        try:
            transcribe.install_progress_hook()
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                with fake.tqdm.tqdm(total=10, unit="frames") as bar:
                    bar.update(10)
        finally:
            del sys.modules["mlx_whisper.transcribe"]
        self.assertEqual(buf.getvalue(), "")

    def test_hook_failure_is_not_fatal(self):
        transcribe = load("vendored_transcribe3", PIPELINE / "transcribe.py")
        sys.modules.pop("mlx_whisper.transcribe", None)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            transcribe.install_progress_hook()  # must not raise
        self.assertIn("progress hook unavailable", err.getvalue())


if __name__ == "__main__":
    unittest.main()
