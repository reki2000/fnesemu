#!/usr/bin/env python3
"""Runs the end-to-end cases of the cores and helps to write them: a case runs a core headless with its media and
input, and compares the screens, the audio and the other outputs with the expected data.

Running the cases:
  scripts/e2e.py list  [target...]
  scripts/e2e.py show  [target...]
  scripts/e2e.py setup [target...]
  scripts/e2e.py run   [target...] [--update] [-j N] [--slow]
  scripts/e2e.py lint

Writing a case:
  scripts/e2e.py shoot <core>/<case> N --every E [--start S] [--input SEQ] [--cols C] [--scale X]
  scripts/e2e.py buttons [<core>/<case>]
  scripts/e2e.py set <core>/<case> --frames N --shots F1,F2,... [--input SEQ] [--note TEXT] [--history TEXT]
  scripts/e2e.py session start <core>/<case>
  scripts/e2e.py session step N [--every E] [--cols C] [--scale X]
  scripts/e2e.py session press SEQ
  scripts/e2e.py session input
  scripts/e2e.py session shot [NAME]
  scripts/e2e.py session state
  scripts/e2e.py session stop

Every command takes --root DIR. A target is <core> or <core>/<case>; no target means all cases.
The default root is packages/fnesemu_core/test/e2e. --root selects another tree with the same layout, whose
files may also be given by absolute paths.

Each [[case]] may carry note (one line), description (what the media is, what it exercises, how it behaves, what
to look at) and [[case.history]] entries (date, text: breakages, investigations, frame changes, expected/
updates); show prints them as the context of a case.

Layout of a root:
  <core>/e2e.toml               the cases of the core ([[case]] tables)
  <core>/<dir>/setup.py         prepares the media and upstream data in <core>/<dir>/.build/
  <core>/<dir>/expected/        expected data kept in the repository

A case with slow = true (minutes long) runs only with --slow.

input gives the button presses as one line, read by the headless runner with a cursor at frame 0
(packages/fnesemu_core/tool/input_sequence.dart):
  @F          moves the cursor to frame F (not before the cursor)
  _N          moves the cursor N frames on
  B / B:N     holds button B for the default length / N frames and moves the cursor by it
  B+C:N       holds several buttons together
  :N          sets the default length (initially 10) until the end of the enclosing [ ] or ( )
  [ ... ]*N   repeats the part N times (no @F inside)
  ( a | b )   runs the parts in parallel from the cursor; the cursor moves to the latest end
  "..."       a button name with a reserved character: @ _ : + [ ] * ( ) | " or a space
e.g. "@150 Start @250 ( right:710 | _12 [A:6 _30]*20 )" presses Start, then holds right while tapping A.
Every core also has the button Reset, which resets the core and keeps the SRAM.

setup runs the setup.py scripts (fetching or building the media); run does not, and skips a case whose media or
upstream reference is missing, so run setup first.
A case may fail its upstream references (under .build/) when e2e.toml gives the reason in "known_failure";
the outputs must still match the data under expected/, which records the current behavior.

shoot runs a case for N frames (with --input in place of its input) and tiles the screenshots saved every E
frames from frame S, with their frame numbers, into sheet.png. buttons prints the button names of a case (or of
the session) as they are written in a sequence.

session start runs core_headless serve for a case in the background; step, press, shot and state control it,
and stop ends it. step advances N frames (with --every, it saves the screenshots of the frames that are
multiples of E and tiles them into sheet.png). press adds the presses of SEQ, read with the cursor at the next
frame (@F is an absolute frame), and logs it in press.log. input prints the input of the logged presses (one
after another, or in parallel where they overlap), e.g. for set --input "$(scripts/e2e.py session input)".

set rewrites the frames, input, note and screenshot checks of a case (the other checks stay) and adds a
[[case.history]] entry, which replaces the last entry when that has the date of today. The headless runner reads
the input first. The screenshots are expected/<case>_NNNNN.png when the case shares its dir, and
expected/frame_NNNNN.png otherwise; screenshots of the case that are no longer checked are deleted. Write the
expected data with run --update afterwards.

The outputs of shoot and session go to packages/fnesemu_core/.dart_tool/e2e/.
Reading the cases needs Python 3.11 or later, and comparing images and audio needs Pillow and numpy.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import regress  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CORE_PKG = ROOT / "packages" / "fnesemu_core"
DEFAULT_ROOT = CORE_PKG / "test" / "e2e"
OUT = CORE_PKG / ".dart_tool" / "e2e"
SERVER = OUT / "server.json"
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

    def base_command(self, exe: Path, command: str):
        """The command of the headless runner with the core, the files and the args, without frames, output and input."""
        s = self.spec
        cmd = [str(exe), command, s.get("core", self.core)]
        cmd += [str(self.path(f)) for f in s["files"]]
        cmd += [str(self.path(a)) if a.startswith(("./", "../")) else a for a in s.get("args", [])]
        return cmd

    def input(self) -> str:
        i = self.spec.get("input", "")
        if not isinstance(i, str):
            raise TypeError("input is not a string")
        return i

    def command(self, out: Path, exe: Path):
        """The command of the headless runner; exe is the compiled runner."""
        s = self.spec
        frames = [c["frame"] for c in self.checks() if "frame" in c]
        cmd = self.base_command(exe, "run") + ["-f", str(s["frames"]), "-o", str(out)]
        if frames:
            cmd += ["-e", str(math.gcd(*frames)), "-s", str(min(frames))]
        else:
            cmd += ["-e", str(s["frames"])]
        if self.input():
            cmd += ["--input", self.input()]
        if any("audio" in c for c in self.checks()):
            cmd.append("-w")
        if any("vram" in c for c in self.checks()):
            cmd.append("-v")
        if any("tty" in c or "tty_fail" in c for c in self.checks()):
            cmd.append("-t")
        return cmd

    def check_input(self, exe: Path) -> str | None:
        """Lets the headless runner read the input; returns the error, or None."""
        r = subprocess.run(self.base_command(exe, "check-input") + ["--input", self.input()], cwd=CORE_PKG,
                           capture_output=True, text=True)
        if r.returncode == 0:
            return None
        lines = (r.stderr or r.stdout).strip().splitlines()
        return next((line for line in lines if "Unhandled exception" not in line), "headless runner error")

    def is_expected(self, p: Path) -> bool:
        """True for paths under expected/, which --update may write."""
        return (self.dir / "expected").resolve() in p.parents


def load_cases(root: Path):
    cases = []
    for f in sorted(root.glob("*/e2e.toml")):
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


_DATA_KEYS = ("expected", "audio", "vram", "tty")


def check_ref(check: dict):
    """The file that a check compares with, or None for a check without one (tty_fail)."""
    return next((check[k] for k in _DATA_KEYS if k in check), None)


def compare_tty(got: Path, ref: Path):
    a, b = got.read_text().splitlines(), ref.read_text().replace("\r", "").splitlines()
    if a == b:
        return True, f"{len(a)} lines"
    first = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    return False, f"{len(a)} lines, expected {len(b)}; first difference at line {first + 1}"


def tty_failures(check: dict, got: Path):
    """The lines of the tty output that report a failure (the pattern of tty_fail)."""
    pat = re.compile(check["tty_fail"])
    lines = got.read_text().splitlines() if got.exists() else []
    bad = [line for line in lines if pat.search(line)]
    return not bad, (f"{len(bad)} failure lines, the first: {bad[0]}" if bad else "no failure lines")


def compare(case: Case, out: Path, say):
    """Returns (matches expected/, matches the upstream references, has upstream references)."""
    ok, upstream_ok, has_upstream = True, True, False
    for check in case.checks():
        if "tty_fail" in check:
            # the result that the program itself reports, like an upstream reference
            good, msg = tty_failures(check, out / "tty.txt")
            tag = "ok  " if good else ("xfail" if "known_failure" in case.spec else "FAIL")
            say(f"  {tag} tty result (upstream): {msg}")
            has_upstream = True
            upstream_ok &= good
            continue
        if "frame" in check:
            label, got = f"frame {check['frame']}", out / f"frame_{check['frame']:05d}.png"
        elif "audio" in check:
            label, got = "audio", out / "audio.wav"
        elif "tty" in check:
            label, got = "tty", out / "tty.txt"
        else:
            label, got = "vram", out / "vram.png"
        ref = case.path(check_ref(check))
        upstream = not case.is_expected(ref)
        has_upstream |= upstream
        if not ref.exists():
            say(f"  FAIL {label}: no expected data {show(ref)} (run with --update)")
            ok = False
            continue
        if not got.exists():
            say(f"  FAIL {label}: the headless runner did not write {got.name}")
            ok = False
            continue
        if "audio" in check:
            good, msg = regress.compare_audio(json.loads(ref.read_text()), got, check.get("tol"))
        elif "tty" in check:
            good, msg = compare_tty(got, ref)
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
        if check_ref(check) is None:
            continue
        ref = case.path(check_ref(check))
        if not case.is_expected(ref):
            continue  # upstream reference data is never overwritten
        ref.parent.mkdir(parents=True, exist_ok=True)
        if "frame" in check:
            shutil.copy(out / f"frame_{check['frame']:05d}.png", ref)
        elif "audio" in check:
            ref.write_text(json.dumps(regress.audio_features(out / "audio.wav")) + "\n")
        elif "tty" in check:
            shutil.copy(out / "tty.txt", ref)
        else:
            shutil.copy(out / "vram.png", ref)
        say(f"  updated {show(ref)}")


def source_hash() -> str:
    """A hash of the sources that the compiled runner depends on."""
    h = hashlib.sha256()
    files = [CORE_PKG / "pubspec.lock"] + sorted((CORE_PKG / "lib").rglob("*.dart")) + sorted((CORE_PKG / "tool").rglob("*.dart"))
    for f in files:
        h.update(str(f.relative_to(CORE_PKG)).encode())
        h.update(f.read_bytes())
    return h.hexdigest()[:16]


def compile_headless() -> Path:
    """Compiles tool/core_headless.dart once (AOT), and caches the executable by the source hash.

    Starting a compiled runner takes milliseconds, while dart run loads and compiles the sources for each case.
    """
    cache = OUT / "bin"
    cache.mkdir(parents=True, exist_ok=True)
    exe = cache / f"core_headless-{source_hash()}"
    if not exe.exists():
        for old in cache.glob("*-*"):
            old.unlink()
        print("compiling tool/core_headless.dart...", flush=True)
        r = subprocess.run(["dart", "compile", "exe", "tool/core_headless.dart", "-o", str(exe)],
                           cwd=CORE_PKG, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"cannot compile tool/core_headless.dart:\n{r.stdout[-2000:]}{r.stderr[-2000:]}")
    return exe


def run_case(case: Case, do_update, slow, exe: Path):
    """Returns ("ok" | "fail" | "xfail" | "skip", report)."""
    lines = []
    if case.spec.get("slow") and not slow:
        return "skip", f"SKIP {case.id}: slow (run with --slow)"
    # the files that setup.py prepares: the media and the upstream references
    prepared = list(case.spec["files"]) + [a for a in case.spec.get("args", []) if a.startswith(("./", "../"))]
    prepared += [ref for ch in case.checks() for k, ref in ch.items()
                 if k in _DATA_KEYS and not case.is_expected(case.path(ref))]
    missing = [f for f in prepared if not case.path(f).exists()]
    if missing:
        return "skip", f"SKIP {case.id}: missing {', '.join(missing)} (run setup first)"
    out = Path(tempfile.mkdtemp(prefix=f"e2e_{case.core}_{case.name}_"))
    cmd = case.command(out, exe)
    started = time.monotonic()
    try:
        r = subprocess.run(cmd, cwd=CORE_PKG, capture_output=True, text=True,
                           timeout=case.spec.get("timeout", 600))
    except subprocess.TimeoutExpired:
        return "fail", f"[{case.id}]\n  FAIL timeout\n  output kept: {out}"
    elapsed = time.monotonic() - started
    if r.returncode != 0:
        return "fail", f"[{case.id}] {elapsed:.1f}s\n  FAIL exit {r.returncode}\n{r.stdout[-800:]}{r.stderr[-800:]}"
    lines.append(f"[{case.id}] {elapsed:.1f}s")
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
    for k in ("core", "files", "args", "frames", "input", "known_failure"):
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
    """Checks that the default tree refers only to files inside itself, that the headless runner reads each input
    and that expected data stays small."""
    errors = []
    exe = compile_headless()
    for c in cases:
        rels = list(c.spec["files"]) + [a for a in c.spec.get("args", []) if a.startswith(("./", "../"))]
        rels += [v for ch in c.checks() for k, v in ch.items() if k in _DATA_KEYS]
        for rel in rels:
            p = c.path(rel)
            if inside_only and (Path(rel).is_absolute() or root.resolve() not in p.parents):
                errors.append(f"{c.id}: {rel} is outside the root")
        if not c.dir.is_dir():
            errors.append(f"{c.id}: no directory {show(c.dir)}")
        for key, why in (("hold", "write :N at the start of input"), ("harness", "core_headless runs every core")):
            if key in c.spec:
                errors.append(f"{c.id}: {key} is no longer read; {why}")
        try:
            if c.input() and (err := c.check_input(exe)):
                errors.append(f"{c.id}: {err}")
        except TypeError as e:
            errors.append(f"{c.id}: {e}")
        size = sum(c.path(v).stat().st_size for ch in c.checks() for k, v in ch.items()
                   if k in _DATA_KEYS and c.is_expected(c.path(v)) and c.path(v).exists())
        if inside_only and size > EXPECTED_LIMIT:
            errors.append(f"{c.id}: expected data is {size} bytes (limit {EXPECTED_LIMIT})")
    names = [c.id for c in cases]
    errors += [f"duplicate case {n}" for n in sorted({n for n in names if names.count(n) > 1})]
    for e in errors:
        print(f"  {e}")
    print(f"lint: {len(cases)} cases, {len(errors)} errors")
    return not errors


def find_case(root: Path, case_id: str) -> Case:
    cases = select(load_cases(root), [case_id])
    if len(cases) != 1:
        sys.exit(f"no case {case_id} in {root}")
    return cases[0]


def sheet(paths, dest: Path, cols=None, scale=0.5):
    """Tiles the screenshots with their frame numbers; cols defaults to up to 12 in a row."""
    from PIL import Image, ImageDraw
    cols = cols or min(len(paths), 12)
    ims = [Image.open(p).convert("RGB") for p in paths]
    w = int(max(i.width for i in ims) * scale)
    h = int(max(i.height for i in ims) * scale)
    rows = (len(ims) + cols - 1) // cols
    img = Image.new("RGB", (cols * (w + 4), rows * (h + 14)), "gray")
    draw = ImageDraw.Draw(img)
    for k, (p, im) in enumerate(zip(paths, ims)):
        x, y = (k % cols) * (w + 4), (k // cols) * (h + 14)
        img.paste(im.resize((int(im.width * scale), int(im.height * scale))), (x, y + 14))
        draw.text((x + 2, y + 1), Path(p).stem.replace("frame_", ""), fill="white")
    img.save(dest)
    print(dest)


def shoot(a):
    case = find_case(a.root, a.case)
    seq = a.input if a.input is not None else case.input()
    out = OUT / "shoot" / case.name
    subprocess.run(["rm", "-rf", str(out)])
    out.mkdir(parents=True)
    cmd = case.base_command(compile_headless(), "run") + ["-f", str(a.frames), "-e", str(a.every), "-o", str(out),
                                                 "-s", str(a.start)]
    if seq:
        cmd += ["--input", seq]
    r = subprocess.run(cmd, cwd=CORE_PKG, capture_output=True, text=True)
    pngs = sorted(p for p in out.glob("frame_*.png") if int(p.stem[6:]) >= a.start)
    if not pngs:
        sys.exit(f"no frames (exit {r.returncode})\n{r.stdout[-1000:]}{r.stderr[-1000:]}")
    sheet(pngs, out / "sheet.png", a.cols, a.scale)


def request(endpoint, **query):
    server = json.loads(SERVER.read_text())
    url = f"http://127.0.0.1:{server['port']}{endpoint}?" + urllib.parse.urlencode(query)
    try:
        with urllib.request.urlopen(url, timeout=3600) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())


def server_dir() -> Path:
    return OUT / "session" / json.loads(SERVER.read_text())["case"]


def buttons(a):
    if a.case is None:
        names = request("/buttons")["buttons"]
    else:
        case = find_case(a.root, a.case)
        r = subprocess.run(case.base_command(compile_headless(), "buttons"), cwd=CORE_PKG,
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(r.stderr[-1000:] or r.stdout[-1000:])
        names = json.loads(r.stdout)
    print(" ".join(quote_button(n) for n in names if n))


def quote_button(name: str) -> str:
    """The name as written in a sequence (the rule of quoteButton in tool/input_sequence.dart)."""
    return f'"{name}"' if any(c in '@_:+[]*()|" \t\n\r' for c in name) else name


def session_start(a):
    case = find_case(a.root, a.case)
    d = OUT / "session" / case.name
    subprocess.run(["rm", "-rf", str(d)])
    d.mkdir(parents=True)
    log = d / "server.log"
    cmd = case.base_command(compile_headless(), "serve") + ["--port", "0"]
    subprocess.Popen(cmd, cwd=CORE_PKG, stdout=open(log, "w"), stderr=subprocess.STDOUT,
                     start_new_session=True)
    text = ""
    for _ in range(600):
        text = log.read_text()
        if "serving on" in text:
            break
        time.sleep(0.1)
    else:
        sys.exit(f"the server did not start:\n{text[-1000:]}")
    port = int(text.split("127.0.0.1:")[1].split()[0])
    SERVER.write_text(json.dumps({"case": case.name, "port": port}))
    print(f"session of {case.id} on port {port}")


def session_step(a):
    if a.every is None:
        print(json.dumps(request("/run", frames=a.frames)))
        return
    d = server_dir() / f"run_{time.time_ns()}"
    r = request("/run", frames=a.frames, every=a.every, dir=str(d))
    pngs = sorted(d.glob("frame_*.png"))
    if pngs:
        sheet(pngs, server_dir() / "sheet.png", a.cols, a.scale)
    print(json.dumps(r))


def session_press(a):
    r = request("/press", seq=a.seq)
    if "error" in r:
        sys.exit(r["error"])
    with open(server_dir() / "press.log", "a") as log:
        log.write(json.dumps({"from": r["from"], "end": r["end"], "seq": a.seq}, ensure_ascii=False) + "\n")
    print(json.dumps({"from": r["from"], "end": r["end"], "presses": r["presses"]}))


def logged_input() -> str:
    """The input of the presses in press.log: one after another, or in parallel when they overlap."""
    path = server_dir() / "press.log"
    entries = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    tracks = []  # [end, [parts]]
    for e in entries:
        at = re.match(r"\s*@(\d+)", e["seq"])
        start = int(at.group(1)) if at else e["from"]
        part = e["seq"] if at else f"@{e['from']} {e['seq']}"
        track = next((t for t in tracks if t[0] <= start), None)
        if track is None:
            track = [0, []]
            tracks.append(track)
        # a default length set in a part must not reach the parts after it
        track[1].append(f"( {part} )" if re.search(r"(^|[\s\[(|]):\d", part) else part)
        track[0] = e["end"]
    if len(tracks) <= 1:
        return " ".join(tracks[0][1]) if tracks else ""
    return "( " + " | ".join(" ".join(t[1]) for t in tracks) + " )"


def session_input(a):
    print(logged_input())


def session_shot(a):
    name = a.name or f"frame_{request('/state')['frame']:05d}"
    print(json.dumps(request("/shot", path=str(server_dir() / f"{name}.png"))))


def session_state(a):
    r = request("/state")
    print(json.dumps({"frame": r["frame"], "pc": hex(r.get("pc", 0))}))


def session_stop(a):
    print(json.dumps(request("/quit")))


def set_case(a):
    case = find_case(a.root, a.case)
    path = a.root / case.core / "e2e.toml"
    blocks = path.read_text().split("[[case]]")
    idx = next(i for i, b in enumerate(blocks) if re.search(rf'^name = "{re.escape(case.name)}"$', b, re.M))
    block = blocks[idx]
    shots = [int(x) for x in a.shots.split(",")]
    prefix = f"{case.name}_" if "dir" in case.spec else "frame_"

    def text(s):
        # a literal string keeps the quotes of the button names readable
        if '"' in s and "'" not in s and "\n" not in s:
            return f"'{s}'"
        return json.dumps(s, ensure_ascii=False)

    def set_line(block, key, value):
        pat = re.compile(rf"^{key} = .*$", re.M)
        line = f"{key} = {value}"
        if pat.search(block):
            return pat.sub(lambda m: line, block, count=1)
        return re.sub(r"^(frames = .*)$", lambda m: m.group(1) + "\n" + line, block, count=1, flags=re.M)

    block = set_line(block, "frames", str(a.frames))
    if a.input is not None:
        case.spec["input"] = a.input
        if a.input and (err := case.check_input(compile_headless())):
            sys.exit(err)
        block = set_line(block, "input", text(a.input))
    if a.note is not None:
        block = set_line(block, "note", text(a.note))
    checks = [f'{{ frame = {f}, expected = "expected/{prefix}{f:05d}.png" }}' for f in shots]
    for c in case.checks():
        if "frame" not in c:
            checks.append("{ " + ", ".join(f"{k} = {text(v)}" for k, v in c.items()) + " }")
    block = set_line(block, "checks", "[" + ", ".join(checks) + "]")
    if a.history is not None:
        today = datetime.date.today().isoformat()
        block = re.sub(rf'\n*\[\[case\.history\]\]\ndate = "{today}"\ntext = .*\n*$', "", block)
        block = block.rstrip("\n") + f'\n\n[[case.history]]\ndate = "{today}"\ntext = {text(a.history)}\n\n'
    blocks[idx] = block
    new = "[[case]]".join(blocks)
    tomllib.loads(new)
    path.write_text(new)
    for p in (case.dir / "expected").glob(f"{prefix}*.png"):
        if p.stem[len(prefix):].isdigit() and int(p.stem[len(prefix):]) not in shots:
            p.unlink()
    print(f"updated {case.id}; run e2e.py run {case.id} --update")


def run_cases(a, root: Path):
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
    started = time.monotonic()
    exe = compile_headless()
    with ThreadPoolExecutor(max(1, a.j)) as ex:
        results = []
        for status, text in ex.map(lambda c: run_case(c, a.update, a.slow, exe), cases):
            print(text, flush=True)
            results.append(status)
    print(f"\n{results.count('ok')} ok, {results.count('fail')} failed, "
          f"{results.count('xfail')} known failures, {results.count('skip')} skipped "
          f"in {time.monotonic() - started:.0f}s")
    sys.exit(1 if "fail" in results else 0)


def main(argv=None):
    root_help = "the tree of the cases (default: packages/fnesemu_core/test/e2e)"
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--root", type=Path, default=argparse.SUPPRESS, help=root_help)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                 parents=[common])
    sub = ap.add_subparsers(dest="action", required=True)

    for action, help_ in (("list", "list the cases"), ("show", "print the cases with their description and history"),
                          ("setup", "fetch or build the media"), ("run", "run the cases and compare the outputs"),
                          ("lint", "check the paths, the inputs and the size of the expected data")):
        p = sub.add_parser(action, help=help_, parents=[common])
        p.add_argument("targets", nargs="*")
        if action == "run":
            p.add_argument("--update", action="store_true", help="write the outputs to the expected/ data")
            p.add_argument("-j", type=int, default=1, help="cases to run in parallel")
            p.add_argument("--slow", action="store_true", help="also run the cases marked slow")
        else:
            p.set_defaults(update=False, j=1, slow=False)
        p.set_defaults(func=None)

    p = sub.add_parser("shoot", help="run a case and tile its screenshots", parents=[common])
    p.add_argument("case")
    p.add_argument("frames", type=int)
    p.add_argument("--every", type=int, required=True)
    p.add_argument("--start", type=int, default=0, help="the first frame to tile")
    p.add_argument("--input", help="the input sequence in place of the input of the case")
    p.add_argument("--cols", type=int, help="screenshots in a row (default: up to 12)")
    p.add_argument("--scale", type=float, default=0.5)
    p.set_defaults(func=shoot)

    p = sub.add_parser("buttons", help="print the button names of a case or of the session", parents=[common])
    p.add_argument("case", nargs="?")
    p.set_defaults(func=buttons)

    p = sub.add_parser("set", help="rewrite the frames, input and screenshots of a case", parents=[common])
    p.add_argument("case")
    p.add_argument("--frames", type=int, required=True)
    p.add_argument("--shots", required=True, help="the frames to check, comma separated")
    p.add_argument("--input", help="the input sequence")
    p.add_argument("--note")
    p.add_argument("--history", help="a [[case.history]] entry")
    p.set_defaults(func=set_case)

    session = sub.add_parser("session", help="run a case frame by frame in the background").add_subparsers(
        dest="session_action", required=True)
    p = session.add_parser("start", help="start the session of a case", parents=[common])
    p.add_argument("case")
    p.set_defaults(func=session_start)
    p = session.add_parser("step", help="advance the session", parents=[common])
    p.add_argument("frames", type=int)
    p.add_argument("--every", type=int)
    p.add_argument("--cols", type=int, help="screenshots in a row (default: up to 12)")
    p.add_argument("--scale", type=float, default=0.5)
    p.set_defaults(func=session_step)
    p = session.add_parser("press", help="add the presses of an input sequence from the next frame", parents=[common])
    p.add_argument("seq")
    p.set_defaults(func=session_press)
    session.add_parser("input", help="print the input of the presses so far, for set --input",
                       parents=[common]).set_defaults(func=session_input)
    p = session.add_parser("shot", help="save the current screen", parents=[common])
    p.add_argument("name", nargs="?", help="the file name without .png (default: frame_NNNNN)")
    p.set_defaults(func=session_shot)
    session.add_parser("state", help="print the frame and the program counter",
                       parents=[common]).set_defaults(func=session_state)
    session.add_parser("stop", help="stop the session", parents=[common]).set_defaults(func=session_stop)

    a = ap.parse_args(argv)
    a.root = getattr(a, "root", DEFAULT_ROOT).resolve()
    if not a.root.is_dir():
        sys.exit(f"no tree of cases: {a.root}")
    if a.func is None:
        run_cases(a, a.root)
    else:
        a.func(a)


if __name__ == "__main__":
    main()
