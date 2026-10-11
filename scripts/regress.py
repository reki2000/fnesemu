#!/usr/bin/env python3
"""軽い回帰 / 実 ROM の画像・音声フル回帰。

  scripts/regress.py run                 # quick: 合成データの全テスト (55秒予算)
  scripts/regress.py run quick           # 同上、ROM・正本・numpy/Pillow は不要
  scripts/regress.py run full            # 全実 ROM case の正本比較 (長時間)
  scripts/regress.py run all             # full の別名
  scripts/regress.py run <case> [--update]
  scripts/regress.py list
  scripts/regress.py compare <case> <out-dir>
  scripts/regress.py update <case> <out-dir>

フル回帰には docs/baseline/cases.json と正本、ROM、Pillow、numpy が必要。
--update は正本の変更を確認したときだけ指定する。
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

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
    import numpy as np
    from PIL import Image

    ia, ib = Image.open(a).convert("RGBA"), Image.open(b).convert("RGBA")
    if ia.size != ib.size:
        return False, f"size {ia.size} != {ib.size}"
    d = np.abs(np.asarray(ia, np.int16) - np.asarray(ib, np.int16)).max(axis=2)
    ratio = float((d > 0).mean())
    return ratio <= PIXEL_TOL, f"diff pixels {ratio * 100:.3f}% max {int(d.max())}"


HWREF_CHANNEL_TOL = 8
HWREF_SLACK = 0.0005


def hwref_ratio(got, ref):
    import numpy as np
    from PIL import Image

    a = np.asarray(Image.open(got).convert("RGB"), np.int16)
    b = np.asarray(Image.open(ref).convert("RGB"), np.int16)
    if a.shape != b.shape:
        return 1.0
    return float((np.abs(a - b).max(axis=2) > HWREF_CHANNEL_TOL).mean())


def audio_features(path):
    import numpy as np

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
    import numpy as np

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
    refs = sorted(d.glob("frame_*.png"))
    if not refs and not (d / "vram.png").exists() and not (d / "audio.json").exists():
        print(f"  FAIL no reference artifacts: {d}")
        return False
    ok = True
    for ref in refs:
        n = frame_no(ref)
        got = find_frame(out, n)
        if got is None:
            print(f"  FAIL frame {n}: not found in {out}")
            ok = False
            continue
        good, msg = compare_png(ref, got)
        print(f"  {'ok  ' if good else 'FAIL'} frame {n}: {msg}")
        ok &= good
    vp = d / "vram.png"
    if vp.exists():
        got = out / "vram.png"
        if not got.exists():
            print("  FAIL vram: vram.png not found (run the harness with --vram)")
            ok = False
        else:
            good, msg = compare_png(vp, got)
            print(f"  {'ok  ' if good else 'FAIL'} vram: {msg}")
            ok &= good
            hw = d / "hwref.json"
            if hw.exists() and c.get("vram_ref"):
                base = json.loads(hw.read_text())["diff"]
                cur = hwref_ratio(got, c["vram_ref"])
                good = cur <= base + HWREF_SLACK
                print(f"  {'ok  ' if good else 'FAIL'} hw reference: diff {cur * 100:.3f}% (baseline {base * 100:.3f}%)")
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
    if c.get("vram_ref") and (out / "vram.png").exists():
        shutil.copy(out / "vram.png", d / "vram.png")
        ratio = hwref_ratio(out / "vram.png", c["vram_ref"])
        (d / "hwref.json").write_text(json.dumps({"diff": ratio}) + "\n")
        print(f"  hw reference diff {ratio * 100:.3f}%")
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


def _kill_process_tree(process):
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=2)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.communicate(timeout=2)
    except subprocess.TimeoutExpired:
        # An escaped descendant may still hold the output pipe open.
        process.stdout.close()
        process.wait(timeout=2)


def run_quick(budget=55.0, suites=None):
    """Run the synthetic-data suites within one total wall-clock budget."""
    suites = suites if suites is not None else [
        ("disc images", ROOT / "packages/cdrom_image",
         ["dart", "test", "--reporter", "expanded"]),
        ("cores", ROOT / "packages/fnesemu_core",
         ["dart", "test", "--reporter", "expanded"]),
        ("app", ROOT, ["flutter", "test", "--no-pub", "--reporter", "expanded"]),
    ]
    started = time.monotonic()
    deadline = started + budget
    for name, cwd, cmd in suites:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(f"FAIL quick budget exhausted before {name} ({budget:g}s)")
            return False
        print(f"[quick] {name}", flush=True)
        suite_started = time.monotonic()
        try:
            process = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True,
                                       start_new_session=os.name != "nt")
        except OSError as error:
            print(f"FAIL cannot start {name}: {error}")
            return False
        try:
            output, _ = process.communicate(timeout=max(0.001, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            _kill_process_tree(process)
            print(f"FAIL quick exceeded its {budget:g}s total budget during {name}")
            return False
        except KeyboardInterrupt:
            _kill_process_tree(process)
            raise
        if process.returncode:
            print(output[-8000:])
            print(f"FAIL {name}: exit {process.returncode}")
            return False
        print(f"  passed ({time.monotonic() - suite_started:.1f}s)")
    print(f"quick passed: {len(suites)} suites in {time.monotonic() - started:.1f}s")
    return True


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["list", "run", "compare", "update"])
    ap.add_argument("case", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--budget", type=float, default=55.0, help="quick suite total budget in seconds (default: 55)")
    a = ap.parse_args(argv)
    if a.action == "run" and a.case in (None, "quick"):
        if a.update:
            ap.error("quick has no ROM baselines to update")
        if a.budget <= 0:
            ap.error("budget must be positive")
        sys.exit(0 if run_quick(a.budget) else 1)
    cases = load_cases()
    if a.action == "list":
        print("quick: synthetic-data suites (default, 55s budget)")
        print("full: all ROM image/audio cases (long running)")
        for c in cases.values():
            print(f"{c['name']:24} {c['core']:6} {c.get('note', '')}")
        return
    if not a.case:
        ap.error("case required")
    if a.case in ("all", "full"):
        targets = list(cases.values())
    elif a.case in cases:
        targets = [cases[a.case]]
    else:
        ap.error(f"unknown case: {a.case}")
    if a.action == "run":
        res = [run(c, a.update) for c in targets]
        print(f"\n{sum(r is True for r in res)} ok, {sum(r is False for r in res)} failed, "
              f"{sum(r is None for r in res)} skipped")
        sys.exit(1 if any(r is False for r in res) or not any(r is True for r in res) else 0)
    if not a.out:
        ap.error("out-dir required")
    if a.action == "compare":
        sys.exit(0 if compare(targets[0], a.out) else 1)
    update(targets[0], a.out)


if __name__ == "__main__":
    main()
