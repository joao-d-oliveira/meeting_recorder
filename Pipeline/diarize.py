"""Two-speaker diarization of whisper word timestamps using ECAPA voice embeddings.

For each recording, embeddings are computed on short sliding windows over the
speech, clustered into 2 voices, and each word is assigned to the closer voice.

Which voice is the interviewer:
  * If a saved interviewer voiceprint exists, the cluster closest to it wins.
    This works for a single recording.
  * Otherwise, with 2+ recordings, the interviewer is the voice that appears
    in every file (cross-file match). The result is saved as the voiceprint so
    later single-file runs work.

Usage:
  python diarize.py OUT_DIR Guest:audio16k.wav:words.json [Guest2:...]
                    [--interviewer Joao] [--voiceprint PATH] [--refresh-voiceprint]

Writes OUT_DIR/<Guest>_Transcript.md for each recording, plus
OUT_DIR/<Guest>_Transcript.summary.json (machine-readable facts about the transcript:
turn count, duration, speaking time, how the interviewer was identified, ...).
"""
import argparse
import json
import os
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from sklearn.cluster import KMeans
from speechbrain.inference.speaker import EncoderClassifier

SR = 16000
WIN = 1.5    # seconds per embedding window
HOP = 0.5    # seconds between windows
CACHE = Path.home() / ".cache/diarize"

_enc = None


def encoder():
    global _enc
    if _enc is None:
        _enc = EncoderClassifier.from_hparams(
            source="speechbrain/spkrec-ecapa-voxceleb", savedir=str(CACHE / "ecapa"))
    return _enc


def l2n(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True)


def load_words(path):
    data = json.load(open(path))
    words = []
    for seg in data["segments"]:
        for w in seg.get("words", []):
            if w["end"] > w["start"]:
                words.append({"start": w["start"], "end": w["end"], "text": w["word"]})
    return words


def speech_windows(words, total):
    """Window start times covering stretches where words are spoken."""
    starts = set()
    for w in words:
        t = max(0.0, w["start"] - WIN / 2)
        while t < w["end"]:
            starts.add(round(t / HOP) * HOP)
            t += HOP
    return sorted(s for s in starts if s + WIN <= total)


def embed(audio, starts, batch=64):
    out = []
    n = int(WIN * SR)
    for i in range(0, len(starts), batch):
        chunk = np.stack([audio[int(s * SR): int(s * SR) + n] for s in starts[i:i + batch]])
        with torch.no_grad():
            e = encoder().encode_batch(torch.from_numpy(chunk).float()).squeeze(1).cpu().numpy()
        out.append(e)
    return l2n(np.concatenate(out))


def smooth(words, labels, max_dur=1.0, max_words=3):
    """Flip short islands (≤3 words / ≤1 s) that sit inside the other speaker's turn."""
    labels = labels[:]
    for _ in range(2):
        i = 0
        while i < len(labels):
            j = i
            while j + 1 < len(labels) and labels[j + 1] == labels[i]:
                j += 1
            if 0 < i and j < len(labels) - 1 and labels[i - 1] == labels[j + 1] != labels[i]:
                dur = words[j]["end"] - words[i]["start"]
                if j - i + 1 <= max_words and dur <= max_dur:
                    for k in range(i, j + 1):
                        labels[k] = labels[i - 1]
            i = j + 1
    return labels


def process(guest, wav, words_json):
    audio, sr = sf.read(wav, dtype="float32")
    assert sr == SR, f"{wav} must be 16 kHz mono"
    if audio.ndim > 1:
        audio = audio.mean(1)
    words = load_words(words_json)
    starts = np.array(speech_windows(words, len(audio) / SR))
    print(f"{guest}: {len(words)} words, {len(starts)} windows", flush=True)
    if len(starts) < 2:
        raise SystemExit(f"{guest}: not enough speech to tell voices apart "
                         f"({len(words)} words, {len(starts)} windows)")
    E = embed(audio, starts)
    km = KMeans(n_clusters=2, n_init=10, random_state=0).fit(E)
    cents = l2n(km.cluster_centers_)

    # Score each word against both voices using the windows that cover it.
    centers = starts + WIN / 2
    sims = E @ cents.T  # (windows, 2)
    labels, margins = [], []
    for w in words:
        mid = (w["start"] + w["end"]) / 2
        m = np.abs(centers - mid) <= WIN / 2
        if not m.any():
            m = np.zeros(len(centers), bool)
            m[np.argmin(np.abs(centers - mid))] = True
        s = sims[m].mean(0)
        labels.append(int(np.argmax(s)))
        margins.append(float(abs(s[0] - s[1])))
    labels = smooth(words, labels)
    return {"guest": guest, "words": words, "labels": labels, "margins": margins, "cents": cents}


def turns(words, labels, margins, gap=1.5):
    out = []
    for w, l, m in zip(words, labels, margins):
        if out and out[-1]["spk"] == l and w["start"] - out[-1]["end"] < gap * 4:
            out[-1]["end"] = w["end"]
            out[-1]["text"] += w["text"]
            out[-1]["m"].append(m)
        else:
            out.append({"spk": l, "start": w["start"], "end": w["end"], "text": w["text"], "m": [m]})
    return out


def ts(t):
    t = int(t)
    return f"{t // 3600:02d}:{t % 3600 // 60:02d}:{t % 60:02d}"


def uncertain(turn):
    """A turn whose voice match is weak; marked (?) in the transcript."""
    return bool(np.median(turn["m"]) < 0.05)


def build_summary(*, guest, interviewer, transcript_path, tt, words, interviewer_cluster,
                  talk, scores, method, how, weak_match):
    """Machine-readable facts about one transcript (see Pipeline/README.md for the schema)."""
    ic = interviewer_cluster
    scores = [round(float(x), 4) for x in scores]
    return {
        "version": 1,
        "transcript_path": str(transcript_path),
        "guest": guest,
        "interviewer": interviewer,
        "turn_count": len(tt),
        "word_count": len(words),
        "duration_seconds": round(float(words[-1]["end"]), 2) if words else 0.0,
        "interviewer_speaking_seconds": round(float(talk[ic]), 2),
        "guest_speaking_seconds": round(float(talk[1 - ic]), 2),
        "identification_method": method,
        "identification": how,
        "interviewer_cluster": int(ic),
        "similarity_scores": scores,
        "interviewer_similarity": scores[ic],
        "guest_similarity": scores[1 - ic],
        "weak_match": bool(weak_match),
        "uncertain_turns": sum(1 for t in tt if uncertain(t)),
    }


def write_json_atomic(path, data):
    tmp = Path(str(path) + ".part")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("specs", nargs="+", help="Guest:audio16k.wav:words.json")
    ap.add_argument("--interviewer", default="Joao")
    ap.add_argument("--voiceprint", default=None,
                    help="default: ~/.cache/diarize/voiceprint-<interviewer>.npy")
    ap.add_argument("--refresh-voiceprint", action="store_true",
                    help="ignore the saved voiceprint and rebuild it from 2+ recordings")
    a = ap.parse_args()

    vp_path = Path(a.voiceprint) if a.voiceprint else CACHE / f"voiceprint-{a.interviewer.lower()}.npy"
    specs = [s.split(":") for s in a.specs]
    for s in specs:
        if len(s) != 3:
            raise SystemExit(f"bad spec {':'.join(s)!r}; expected Guest:audio.wav:words.json")
    res = [process(g, w, j) for g, w, j in specs]

    use_vp = vp_path.exists() and not a.refresh_voiceprint
    if use_vp:
        vp = l2n(np.load(vp_path))
        for r in res:
            score = r["cents"] @ vp
            r["joao"] = int(np.argmax(score))
            r["how"] = f"voiceprint similarity {np.round(score, 3)}"
            r["method"] = "voiceprint"
            r["scores"] = score
            r["weak"] = bool(score.max() < 0.5 or abs(score[0] - score[1]) < 0.2)
            if r["weak"]:
                print(f"WARNING {r['guest']}: weak voiceprint match {np.round(score, 3)}; "
                      "check the labels by reading the first few turns", flush=True)
    elif len(res) >= 2:
        for r in res:
            others = [o for o in res if o is not r]
            score = [np.mean([max(r["cents"][c] @ o["cents"].T) for o in others]) for c in (0, 1)]
            r["joao"] = int(np.argmax(score))
            r["how"] = f"cross-file similarity {np.round(score, 3)}"
            r["method"] = "cross-file"
            r["scores"] = score
            r["weak"] = False  # the weak-match rule only applies to voiceprint matching
        vp = l2n(np.mean([r["cents"][r["joao"]] for r in res], axis=0))
        vp_path.parent.mkdir(parents=True, exist_ok=True)
        np.save(vp_path, vp)
        print(f"saved interviewer voiceprint to {vp_path}", flush=True)
    else:
        raise SystemExit(
            f"No voiceprint at {vp_path} and only one recording. Either pass 2+ recordings "
            "that share the interviewer (this builds the voiceprint), or pass --voiceprint.")

    out_dir = Path(a.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for r in res:
        guest = r["guest"]
        print(f"{guest}: {r['how']} -> cluster {r['joao']} is {a.interviewer}", flush=True)
        names = {r["joao"]: f"{a.interviewer} (Interviewer)", 1 - r["joao"]: f"{guest} (Interviewee)"}
        tt = turns(r["words"], r["labels"], r["margins"])
        talk = {k: sum(t["end"] - t["start"] for t in tt if t["spk"] == k) for k in (0, 1)}
        lines = [f"# Interview with {guest}\n",
                 f"Speaking time: {a.interviewer} {talk[r['joao']] / 60:.1f} min, "
                 f"{guest} {talk[1 - r['joao']] / 60:.1f} min. "
                 "Turns marked (?) had a weak voice match; check them by ear.\n"]
        for t in tt:
            flag = " (?)" if uncertain(t) else ""
            lines.append(f"**[{ts(t['start'])}] {names[t['spk']]}{flag}:** {t['text'].strip()}\n")
        path = out_dir / f"{guest}_Transcript.md"
        path.write_text("\n".join(lines))
        print(f"wrote {path} ({len(tt)} turns)", flush=True)
        summary_path = out_dir / f"{guest}_Transcript.summary.json"
        write_json_atomic(summary_path, build_summary(
            guest=guest, interviewer=a.interviewer, transcript_path=path.absolute(),
            tt=tt, words=r["words"], interviewer_cluster=r["joao"], talk=talk,
            scores=r["scores"], method=r["method"], how=r["how"], weak_match=r["weak"]))
        print(f"wrote {summary_path}", flush=True)


if __name__ == "__main__":
    main()
