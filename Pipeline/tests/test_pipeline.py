"""Model-free checks for the vendored pipeline.

Run with the pipeline's own interpreter (it has numpy/torch/speechbrain installed):

    ~/.cache/diarize/.venv/bin/python -I Pipeline/tests/test_pipeline.py

Covers: the summary.json writer, that the .md output is byte-identical to the original
skill's diarize.py for the same input, where diarize.py may write the voiceprint, and the
transcribe.py progress hook and part-file argument. Uses fabricated data and a temp
directory only; no model is loaded and nothing is written to the user's cache (the tests
that run main() without --voiceprint point diarize.CACHE at a temp directory first).
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


def fabricated_recording(guest="Fab"):
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
    return {"guest": guest, "words": words, "labels": labels, "margins": margins, "cents": cents}


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


def run_main_default_voiceprint(module, out_dir, guests, interviewer="Joao"):
    """Runs module.main() without --voiceprint (so the default path inside module.CACHE is
    used) on one fabricated recording per guest. Returns the printed output."""
    module.process = lambda guest, wav, words_json: fabricated_recording(guest)
    argv = sys.argv
    sys.argv = ["diarize.py", str(out_dir), *[f"{g}:x.wav:x.json" for g in guests],
                "--interviewer", interviewer]
    try:
        with contextlib.redirect_stdout(io.StringIO()) as out:
            module.main()
    finally:
        sys.argv = argv
    return out.getvalue()


def tree(root):
    return sorted(str(p.relative_to(root)) for p in Path(root).rglob("*"))


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


class DefaultVoiceprintPathTests(unittest.TestCase):
    """The default voiceprint path (~/.cache/diarize/voiceprint-<interviewer>.npy) is only
    ever written from 2+ recordings, and never outside the cache folder."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.cache = self.root / "home/.cache/diarize"
        self.cache.mkdir(parents=True)
        self.out = self.root / "out"
        self.diarize = load("vendored_diarize_vp", PIPELINE / "diarize.py")
        self.diarize.CACHE = self.cache  # never the real ~/.cache/diarize
        self.assertNotEqual(self.diarize.CACHE, Path.home() / ".cache/diarize")

    def tearDown(self):
        self.tmp.cleanup()

    def test_one_recording_without_a_voiceprint_fails_and_writes_nothing(self):
        before = tree(self.root)
        with self.assertRaises(SystemExit) as caught:
            run_main_default_voiceprint(self.diarize, self.out, ["Solo"])
        message = str(caught.exception)
        self.assertIn("No voiceprint at", message)
        self.assertIn(str(self.cache / "voiceprint-joao.npy"), message)
        self.assertIn("only one recording", message)
        self.assertEqual(tree(self.root), before)  # no voiceprint, no output folder, no transcript

    def test_two_recordings_save_the_voiceprint_in_the_cache_folder(self):
        run_main_default_voiceprint(self.diarize, self.out, ["A", "B"], interviewer="Maria")
        saved = self.cache / "voiceprint-maria.npy"
        self.assertTrue(saved.exists())
        self.assertAlmostEqual(float(np.linalg.norm(np.load(saved))), 1.0, places=5)
        self.assertEqual(sorted(p.name for p in self.cache.iterdir()), ["voiceprint-maria.npy"])

    def test_saved_voiceprint_is_used_by_a_later_single_recording_run(self):
        run_main_default_voiceprint(self.diarize, self.out, ["A", "B"])
        out = run_main_default_voiceprint(self.diarize, self.out, ["Solo"])
        summary = json.loads((self.out / "Solo_Transcript.summary.json").read_text())
        self.assertEqual(summary["identification_method"], "voiceprint")
        self.assertIn("wrote", out)

    def test_a_hostile_interviewer_name_cannot_write_outside_the_cache(self):
        for name in ["x/../../evil", "../evil", "a/b", "/abs/evil", "../../../../tmp/evil"]:
            with self.subTest(name=name):
                before = tree(self.root)
                with self.assertRaises(SystemExit) as caught:
                    run_main_default_voiceprint(self.diarize, self.out, ["A", "B"], interviewer=name)
                self.assertIn("outside", str(caught.exception))
                self.assertEqual(tree(self.root), before)  # nothing saved, no directory created

    def test_the_check_applies_to_reading_too(self):
        # A name that escapes the cache is refused even when there is a file to load there.
        (self.root / "home/.cache").mkdir(exist_ok=True)
        np.save(self.root / "home/.cache/evil.npy", np.ones(8, dtype=np.float32))
        with self.assertRaises(SystemExit) as caught:
            run_main_default_voiceprint(self.diarize, self.out, ["Solo"], interviewer="x/../../evil")
        self.assertIn("outside", str(caught.exception))

    def test_an_explicit_voiceprint_path_is_the_callers_choice(self):
        elsewhere = self.root / "elsewhere/vp.npy"
        elsewhere.parent.mkdir()
        self.diarize.process = lambda guest, wav, words_json: fabricated_recording(guest)
        argv = sys.argv
        sys.argv = ["diarize.py", str(self.out), "A:x.wav:x.json", "B:x.wav:x.json",
                    "--interviewer", "Joao", "--voiceprint", str(elsewhere)]
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                self.diarize.main()
        finally:
            sys.argv = argv
        self.assertTrue(elsewhere.exists())
        self.assertEqual(list(self.cache.iterdir()), [])


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


class TranscribePartFileTests(unittest.TestCase):
    """run.sh gives transcribe.py a part-file name of its own (concurrent runs on the same
    recording must not share one); the default is output.json + '.part'."""

    def run_transcribe(self, argv_tail):
        transcribe = load("vendored_transcribe_part", PIPELINE / "transcribe.py")
        transcribe.EMIT_PROGRESS = False
        fake = types.ModuleType("mlx_whisper")
        fake.transcribe = lambda *args, **kwargs: {"segments": [{"words": []}], "text": ""}
        sys.modules["mlx_whisper"] = fake
        replaced = []
        real_replace = transcribe.os.replace
        transcribe.os.replace = lambda src, dst: (replaced.append((src, dst)), real_replace(src, dst))
        argv = sys.argv
        sys.argv = ["transcribe.py", *argv_tail]
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                transcribe.main()
        finally:
            sys.argv = argv
            transcribe.os.replace = real_replace
            del sys.modules["mlx_whisper"]
        return replaced

    def test_uses_the_given_part_file_and_renames_it_into_place(self):
        with tempfile.TemporaryDirectory() as tmp:
            dst, part = Path(tmp) / "k.json", Path(tmp) / "k.json.123.part"
            replaced = self.run_transcribe(["in.wav", str(dst), str(part)])
            self.assertEqual(replaced, [(str(part), str(dst))])
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), ["k.json"])
            self.assertEqual(json.loads(dst.read_text())["segments"], [{"words": []}])

    def test_default_part_file_is_the_output_plus_part(self):
        with tempfile.TemporaryDirectory() as tmp:
            dst = Path(tmp) / "k.json"
            replaced = self.run_transcribe(["in.wav", str(dst)])
            self.assertEqual(replaced, [(str(dst) + ".part", str(dst))])
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), ["k.json"])


if __name__ == "__main__":
    unittest.main()
