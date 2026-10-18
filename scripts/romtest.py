#!/usr/bin/env python3
"""Runs the ROM harness cases of a ROM tree and compares the outputs with the expected data.

  scripts/romtest.py list  [target...] [--root DIR]
  scripts/romtest.py setup [target...] [--root DIR]
  scripts/romtest.py run   [target...] [--root DIR] [--update] [-j N]
  scripts/romtest.py lint  [--root DIR]
  scripts/romtest.py show  [target...] [--root DIR]

A target is <core> or <core>/<case>; no target means all cases.
The default root is packages/fnesemu_core/test/roms. --root selects another tree with the same layout, whose
files may also be given by absolute paths.

Each [[case]] may carry note (one line), description (what the ROM is, what it exercises, how it behaves, what to
look at) and [[case.history]] entries (date, text: breakages, investigations, frame changes, expected/ updates);
show prints them as the context of a case.

Layout of a root:
  <core>/roms.toml              the cases of the core ([[case]] tables)
  <core>/<dir>/setup.py         prepares the ROM and upstream data in <core>/<dir>/.build/
  <core>/<dir>/expected/        expected data kept in the repository

setup runs the setup.py scripts (fetching or building the ROMs); run does not, and skips a case whose ROM or
upstream reference is missing, so run setup first.
A case may fail its upstream references (under .build/) when roms.toml gives the reason in "known_failure";
the outputs must still match the data under expected/, which records the current behavior.
Reading the cases needs Python 3.11 or later, and comparing images and audio needs Pillow and numpy.
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import tomllib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import regress  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CORE_PKG = ROOT / "packages" / "fnesemu_core"
DEFAULT_ROOT = CORE_PKG / "test" / "roms"
EXPECTED_LIMIT = 256 * 1024  # bytes of expected/ data per case


def show(p: Path) -> str:
    return str(p.relative_to(ROOT)) if ROOT in p.parents else str(p)


class Case:
    def __init__(self, root: Path, core: str, spec: dict):
        self.core = core
        self.spec = spec
        self.name = spec["name"]
        self.id = f"{core}/{self.name}"
        self.dir = root / core / spec.get("dir", self.name)

    def path(self, rel: str) -> Path:
        return (self.dir / rel).resolve()

    def checks(self):
        return self.spec.get("checks", [])

    def command(self, out: Path):
        s = self.spec
        frames = [c["frame"] for c in self.checks() if "frame" in c]
        harness = s.get("harness", "core_harness.dart")
        cmd = ["dart", "run", f"tool/{harness}"]
        if harness == "core_harness.dart":
            cmd.append(s.get("core", self.core))
        cmd += [str(self.path(f)) for f in s["files"]]
        cmd += [str(self.path(a)) if a.startswith(("./", "../")) else a for a in s.get("args", [])]
        cmd += ["-f", str(s["frames"]), "-o", str(out)]
        if frames:
            cmd += ["-e", str(math.gcd(*frames))]
            if harness == "core_harness.dart":
                cmd += ["-s", str(min(frames))]
        else:
            cmd += ["-e", str(s["frames"])]
        for f, b in s.get("input", []):
            cmd += ["-p", f"{f}:{b}"]
        if "hold" in s:
            cmd += ["-H", str(s["hold"])]
        if any("audio" in c for c in self.checks()):
            cmd.append("-w")
        if any("vram" in c for c in self.checks()):
            cmd.append("-v")
        return cmd

    def is_expected(self, p: Path) -> bool:
        """True for paths under expected/, which --update may write."""
        return (self.dir / "expected").resolve() in p.parents


def load_cases(root: Path):
    cases = []
    for f in sorted(root.glob("*/roms.toml")):
        cases += [Case(root, f.parent.name, s) for s in tomllib.loads(f.read_text()).get("case", [])]
    return cases


def select(cases, targets):
    if not targets:
        return cases
    picked = [c for c in cases if c.core in targets or c.id in targets]
    unknown = [t for t in targets if not any(t in (c.core, c.id) for c in cases)]
    if unknown:
        sys.exit(f"unknown target: {', '.join(unknown)}")
    return picked


def _setup_dirs(case: Case):
    """The case dir and the dirs whose .build/ the case refers to (such as a BIOS shared by the cases of a core)."""
    yield case.dir
    for rel in list(case.spec["files"]) + [a for a in case.spec.get("args", []) if a.startswith(("./", "../"))]:
        p = case.path(rel)
        owner = next((q.parent for q in p.parents if q.name == ".build"), None)
        if owner is not None:
            yield owner


def setup(cases):
    """Runs each setup.py once; returns the set of dirs that are ready."""
    ready = set()
    for d in dict.fromkeys(d for c in cases for d in _setup_dirs(c)):
        script = d / "setup.py"
        if not script.exists():
            ready.add(d)
            continue
        # setup.py imports setuplib from test/ wherever the root is
        env = {**os.environ, "PYTHONPATH": os.pathsep.join(filter(None, [str(CORE_PKG / "test"), os.environ.get("PYTHONPATH")]))}
        r = subprocess.run([sys.executable, str(script)], capture_output=True, text=True, env=env)
        if r.returncode == 0:
            ready.add(d)
        else:
            print(f"  setup failed: {show(d)}: {(r.stdout + r.stderr).strip()[-400:]}")
    return ready


def compare_frame(check, got: Path, ref: Path):
    import numpy as np
    from PIL import Image

    a = np.asarray(Image.open(got).convert("RGB")).copy()
    b = np.asarray(Image.open(ref).convert("RGB"))
    if a.shape != b.shape:
        return False, f"size {a.shape[1]}x{a.shape[0]} != {b.shape[1]}x{b.shape[0]}"
    # maps the colors of the core to those of an upstream reference image
    mapped = a.copy()
    for src, dst in check.get("palette", {}).items():
        if not (isinstance(src, str) and isinstance(dst, str)):
            raise ValueError(f"palette colors must be hex strings: {src!r}: {dst!r}")
        mask = (a == np.frombuffer(bytes.fromhex(src), np.uint8)).all(axis=2)
        mapped[mask] = np.frombuffer(bytes.fromhex(dst), np.uint8)
    d = np.abs(mapped.astype(np.int16) - b.astype(np.int16)).max(axis=2)
    ratio = float((d > check.get("channel_tol", 0)).mean())
    return ratio <= check.get("max_diff", 0.0), f"diff pixels {ratio * 100:.3f}%"


def compare(case: Case, out: Path, say):
    """Returns (matches expected/, matches the upstream references, has upstream references)."""
    ok, upstream_ok, has_upstream = True, True, False
    for check in case.checks():
        if "frame" in check:
            label, got = f"frame {check['frame']}", out / f"frame_{check['frame']:05d}.png"
        elif "audio" in check:
            label, got = "audio", out / "audio.wav"
        else:
            label, got = "vram", out / "vram.png"
        ref = case.path(check.get("expected") or check.get("audio") or check.get("vram"))
        upstream = not case.is_expected(ref)
        has_upstream |= upstream
        if not ref.exists():
            say(f"  FAIL {label}: no expected data {show(ref)} (run with --update)")
            ok = False
            continue
        if not got.exists():
            say(f"  FAIL {label}: the harness did not write {got.name}")
            ok = False
            continue
        if "audio" in check:
            good, msg = regress.compare_audio(json.loads(ref.read_text()), got, check.get("tol"))
        else:
            good, msg = compare_frame(check, got, ref)
        tag = "ok  " if good else ("xfail" if upstream and "known_failure" in case.spec else "FAIL")
        say(f"  {tag} {label}{' (upstream)' if upstream else ''}: {msg}")
        if upstream:
            upstream_ok &= good
        else:
            ok &= good
    return ok, upstream_ok, has_upstream


def update(case: Case, out: Path, say):
    for check in case.checks():
        ref = case.path(check.get("expected") or check.get("audio") or check.get("vram"))
        if not case.is_expected(ref):
            continue  # upstream reference data is never overwritten
        ref.parent.mkdir(parents=True, exist_ok=True)
        if "frame" in check:
            shutil.copy(out / f"frame_{check['frame']:05d}.png", ref)
        elif "audio" in check:
            ref.write_text(json.dumps(regress.audio_features(out / "audio.wav")) + "\n")
        else:
            shutil.copy(out / "vram.png", ref)
        say(f"  updated {show(ref)}")


def run_case(case: Case, do_update):
    """Returns ("ok" | "fail" | "xfail" | "skip", report)."""
    lines = []
    # the files that setup.py prepares: the ROM and the upstream references
    prepared = list(case.spec["files"]) + [a for a in case.spec.get("args", []) if a.startswith(("./", "../"))]
    prepared += [ref for ch in case.checks() for k, ref in ch.items()
                 if k in ("expected", "audio", "vram") and not case.is_expected(case.path(ref))]
    missing = [f for f in prepared if not case.path(f).exists()]
    if missing:
        return "skip", f"SKIP {case.id}: missing {', '.join(missing)} (run setup first)"
    out = Path(tempfile.mkdtemp(prefix=f"romtest_{case.core}_{case.name}_"))
    cmd = case.command(out)
    try:
        r = subprocess.run(cmd, cwd=CORE_PKG, capture_output=True, text=True,
                           timeout=case.spec.get("timeout", 600))
    except subprocess.TimeoutExpired:
        return "fail", f"[{case.id}]\n  FAIL harness timeout\n  output kept: {out}"
    if r.returncode != 0:
        return "fail", f"[{case.id}]\n  FAIL harness exit {r.returncode}\n{r.stdout[-800:]}{r.stderr[-800:]}"
    lines.append(f"[{case.id}]")
    if do_update:
        update(case, out, lines.append)
    ok, upstream_ok, has_upstream = compare(case, out, lines.append)
    known = case.spec.get("known_failure")
    if known:
        lines.append(f"  known failure: {known}")
    if ok and upstream_ok and known and has_upstream:
        lines.append("  XPASS: the upstream references match now; remove known_failure")
    if not ok or (not upstream_ok and not known):
        status = "fail"
    else:
        status = "xfail" if not upstream_ok else "ok"
    if status == "ok":
        shutil.rmtree(out, ignore_errors=True)
    else:
        lines.append(f"  output kept: {out}")
    return status, "\n".join(lines)


def show_case(case: Case):
    """Prints a case with its description and history, the context for investigating it."""
    s = case.spec
    print(f"[{case.id}] {s.get('note', '')}")
    for k in ("harness", "core", "files", "args", "frames", "input", "hold", "known_failure"):
        if k in s:
            print(f"  {k}: {s[k]}")
    for ch in case.checks():
        print(f"  check: {ch}")
    if "description" in s:
        print("  description:")
        print("\n".join(f"    {line}" for line in s["description"].strip().splitlines()))
    for h in s.get("history", []):
        print(f"  history {h.get('date', '')}:")
        print("\n".join(f"    {line}" for line in str(h.get("text", "")).strip().splitlines()))
    print()


def lint(root: Path, cases, inside_only: bool):
    """Checks that the default tree refers only to files inside itself, and that expected data stays small."""
    errors = []
    for c in cases:
        rels = list(c.spec["files"]) + [a for a in c.spec.get("args", []) if a.startswith(("./", "../"))]
        rels += [v for ch in c.checks() for k, v in ch.items() if k in ("expected", "audio", "vram")]
        for rel in rels:
            p = c.path(rel)
            if inside_only and (Path(rel).is_absolute() or root.resolve() not in p.parents):
                errors.append(f"{c.id}: {rel} is outside the root")
        if not c.dir.is_dir():
            errors.append(f"{c.id}: no directory {show(c.dir)}")
        size = sum(c.path(v).stat().st_size for ch in c.checks() for k, v in ch.items()
                   if k in ("expected", "audio", "vram") and c.is_expected(c.path(v)) and c.path(v).exists())
        if inside_only and size > EXPECTED_LIMIT:
            errors.append(f"{c.id}: expected data is {size} bytes (limit {EXPECTED_LIMIT})")
    names = [c.id for c in cases]
    errors += [f"duplicate case {n}" for n in sorted({n for n in names if names.count(n) > 1})]
    for e in errors:
        print(f"  {e}")
    print(f"lint: {len(cases)} cases, {len(errors)} errors")
    return not errors


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["list", "setup", "run", "lint", "show"])
    ap.add_argument("targets", nargs="*")
    ap.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="the ROM tree (default: %(default)s)")
    ap.add_argument("--update", action="store_true", help="write the outputs to the expected/ data")
    ap.add_argument("-j", type=int, default=1, help="cases to run in parallel")
    a = ap.parse_args(argv)
    root = a.root.resolve()
    if not root.is_dir():
        sys.exit(f"no ROM tree: {root}")
    cases = select(load_cases(root), a.targets)

    if a.action == "list":
        for c in cases:
            print(f"{c.id:36} {c.spec.get('note', '')}")
        return
    if a.action == "show":
        for c in cases:
            show_case(c)
        return
    if a.action == "lint":
        sys.exit(0 if lint(root, cases, inside_only=root == DEFAULT_ROOT.resolve()) else 1)
    if a.action == "setup":
        ready = setup(cases)
        failed = len({d for c in cases for d in _setup_dirs(c)}) - len(ready)
        print(f"{len(ready)} ready, {failed} failed")
        return
    with ThreadPoolExecutor(max(1, a.j)) as ex:
        results = []
        for status, text in ex.map(lambda c: run_case(c, a.update), cases):
            print(text, flush=True)
            results.append(status)
    print(f"\n{results.count('ok')} ok, {results.count('fail')} failed, "
          f"{results.count('xfail')} known failures, {results.count('skip')} skipped")
    sys.exit(1 if "fail" in results else 0)


if __name__ == "__main__":
    main()
