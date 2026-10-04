#!/usr/bin/env python3
"""スクリーンショット / 音声の回帰テスト。

正本 (docs/baseline/<core>/<case>/) と、各ハーネスで取得した結果を比較する。
ハーネスはブランチごとにあるため、case は worktree 名とコマンドを持つ (docs/baseline/cases.json)。

  scripts/regress.py list
  scripts/regress.py run <case|all> [--update]   # worktree でハーネスを実行して比較 (--update: 正本を更新)
  scripts/regress.py compare <case> <out-dir>    # 実行済みの出力ディレクトリと比較
  scripts/regress.py update  <case> <out-dir>    # 出力ディレクトリから正本を作る

正本:
  frame_NNNNN.png  取得したフレーム。出力側とはファイル名末尾の数字 (フレーム番号) で突き合わせる
  audio.json       audio.wav の特徴量 (100ms 窓ごとの RMS と帯域エネルギー、PCM の sha1)
要 Pillow / numpy。
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / "docs" / "baseline"
WT_ROOT = ROOT.parent / "fnesemu-wt"  # worktree 置き場 (docs/TEST.md 参照)

PIXEL_TOL = 0.0  # 差分ピクセル率の許容 (0: 完全一致)
AUDIO_RMS_TOL = 0.05  # 窓ごとの RMS 差 (フルスケール比)
AUDIO_BAND_TOL = 0.10  # 窓ごとの帯域エネルギー比の差
WINDOW_SEC = 0.1


def load_cases():
    return {c["name"]: c for c in json.loads((BASE / "cases.json").read_text())}


def case_dir(c):
    return BASE / c["core"] / c["name"]


def frame_no(p):
    m = re.search(r"(\d+)$", p.stem)
    return int(m.group(1)) if m else None


def find_frame(out, n):
    for p in sorted(out.glob("*.png")):
        if "layer" not in p.stem and frame_no(p) == n:
            return p
    return None


def compare_png(a, b):
    ia, ib = Image.open(a).convert("RGBA"), Image.open(b).convert("RGBA")
    if ia.size != ib.size:
        return False, f"size {ia.size} != {ib.size}"
    d = np.abs(np.asarray(ia, np.int16) - np.asarray(ib, np.int16)).max(axis=2)
    ratio = float((d > 0).mean())
    return ratio <= PIXEL_TOL, f"diff pixels {ratio * 100:.3f}% max {int(d.max())}"


def audio_features(path):
    with wave.open(str(path)) as w:
        rate, ch = w.getframerate(), w.getnchannels()
        pcm = w.readframes(w.getnframes())
    x = np.frombuffer(pcm, np.int16).astype(np.float32) / 32768
    mono = x.reshape(-1, ch).mean(axis=1)
    if rate > 48000:  # NES / PCE は 400kHz 超のレートで出力されるので間引く
        k = rate // 44100
        mono = mono[:len(mono) // k * k].reshape(-1, k).mean(axis=1)
        rate //= k
    n = max(1, int(rate * WINDOW_SEC))
    rms, bands = [], []
    for i in range(0, len(mono) - n + 1, n):
        w_ = mono[i:i + n]
        rms.append(round(float(np.sqrt((w_ ** 2).mean())), 4))
        spec = np.abs(np.fft.rfft(w_ * np.hanning(n))) ** 2
        # 帯域: ~200 / 200-800 / 800-3k / 3k-8k / 8k~ Hz
        edges = [0, 200, 800, 3000, 8000, rate / 2 + 1]
        f = np.fft.rfftfreq(n, 1 / rate)
        e = np.array([spec[(f >= lo) & (f < hi)].sum() for lo, hi in zip(edges, edges[1:])])
        bands.append([round(float(v), 3) for v in e / (e.sum() + 1e-12)])
    return {"rate": rate, "channels": ch, "window_sec": WINDOW_SEC,
            "sha1": hashlib.sha1(pcm).hexdigest(), "rms": rms, "bands": bands}


def compare_audio(base, wav_path, tol=None):
    tol = tol or {}
    rms_tol = tol.get("rms", AUDIO_RMS_TOL)
    band_tol = tol.get("band", AUDIO_BAND_TOL)
    cur = audio_features(wav_path)
    if cur["sha1"] == base["sha1"]:
        return True, "pcm identical"
    n = min(len(cur["rms"]), len(base["rms"]))
    if abs(len(cur["rms"]) - len(base["rms"])) > 1:
        return False, f"length {len(cur['rms'])} != {len(base['rms'])} windows"
    dr = np.abs(np.array(cur["rms"][:n]) - np.array(base["rms"][:n]))
    db = np.abs(np.array(cur["bands"][:n]) - np.array(base["bands"][:n])).max(axis=1)
    bad = int(((dr > rms_tol) | (db > band_tol)).sum())
    ok = bad == 0
    return ok, (f"pcm differs; {bad}/{n} windows out of tolerance "
                f"(max rms diff {dr.max():.3f}, max band diff {db.max():.3f})")


def compare(c, out):
    out = Path(out)
    d = case_dir(c)
    ok = True
    for ref in sorted(d.glob("frame_*.png")):
        n = frame_no(ref)
        got = find_frame(out, n)
        if got is None:
            print(f"  FAIL frame {n}: not found in {out}")
            ok = False
            continue
        good, msg = compare_png(ref, got)
        print(f"  {'ok  ' if good else 'FAIL'} frame {n}: {msg}")
        ok &= good
    af = d / "audio.json"
    if af.exists():
        wav = out / "audio.wav"
        if not wav.exists():
            print("  FAIL audio: audio.wav not found (run the harness with -w)")
            ok = False
        else:
            good, msg = compare_audio(json.loads(af.read_text()), wav, c.get("audio_tol"))
            print(f"  {'ok  ' if good else 'FAIL'} audio: {msg}")
            ok &= good
    return ok


def update(c, out):
    out = Path(out)
    d = case_dir(c)
    frames = c.get("frames")
    old = {frame_no(p): p for p in d.glob("frame_*.png")}
    nums = frames if frames else sorted(old)
    d.mkdir(parents=True, exist_ok=True)
    for n in nums:
        src = find_frame(out, n)
        if src is None:
            sys.exit(f"frame {n} not found in {out}")
        shutil.copy(src, d / f"frame_{n:05d}.png")
    if c.get("audio"):
        (d / "audio.json").write_text(json.dumps(audio_features(out / "audio.wav")) + "\n")
    print(f"updated {d}")


def worktree(c):
    wt = c.get("worktree", "")
    return ROOT if wt == "." else WT_ROOT / wt


def run(c, do_update):
    cwd = worktree(c)
    if not cwd.exists():
        print(f"  SKIP {c['name']}: worktree not found: {cwd}")
        return None
    out = Path(tempfile.mkdtemp(prefix=f"regress_{c['name']}_"))
    cmd = [a.replace("{out}", str(out)) for a in c["cmd"]]
    print(f"[{c['name']}] ({cwd.name}) {' '.join(cmd)}")
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  FAIL harness exit {r.returncode}\n{r.stdout[-800:]}{r.stderr[-800:]}")
        return False
    if do_update:
        update(c, out)
        return True
    ok = compare(c, out)
    if not ok:
        print(f"  output kept: {out}")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["list", "run", "compare", "update"])
    ap.add_argument("case", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--update", action="store_true")
    a = ap.parse_args()
    cases = load_cases()
    if a.action == "list":
        for c in cases.values():
            print(f"{c['name']:24} {c['core']:6} {c.get('worktree', ''):12} {c.get('note', '')}")
        return
    if not a.case:
        ap.error("case required")
    targets = list(cases.values()) if a.case == "all" else [cases[a.case]]
    if a.action == "run":
        res = [run(c, a.update) for c in targets]
        print(f"\n{sum(r is True for r in res)} ok, {sum(r is False for r in res)} failed, "
              f"{sum(r is None for r in res)} skipped")
        sys.exit(1 if any(r is False for r in res) else 0)
    if not a.out:
        ap.error("out-dir required")
    if a.action == "compare":
        sys.exit(0 if compare(targets[0], a.out) else 1)
    update(targets[0], a.out)


if __name__ == "__main__":
    main()
