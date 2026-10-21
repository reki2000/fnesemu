#!/usr/bin/env python3
"""Tools for writing the cases of a ROM tree: try inputs, pick the frames and record them in roms.toml.

  scripts/romtool.py shoot <core>/<case> FRAMES EVERY [--input JSON] [--hold N] [--start N] [--cols N] [--scale S]
  scripts/romtool.py serve <core>/<case>
  scripts/romtool.py run N [--every E] [--cols N]
  scripts/romtool.py press "<sequence>"
  scripts/romtool.py shot NAME
  scripts/romtool.py state
  scripts/romtool.py stop
  scripts/romtool.py set <core>/<case> --frames N --shots F1,F2,... [--input JSON] [--hold N] [--note TEXT]
                         [--history TEXT]

Every command takes --root DIR like romtest.py (default: packages/fnesemu_core/test/roms).

shoot runs the case (with --input in place of its input, given as JSON in the roms.toml input syntax) and tiles
the screenshots saved every EVERY frames, with their frame numbers, into sheet.png.

serve starts core_harness --serve for the case in the background; run, press, shot and state control it, and stop
ends it. run advances N frames (with --every, it saves shots and tiles them into sheet.png). press schedules an
input sequence; its cursor starts at the next frame, so @F is relative to it. Each press is logged with its start
frame in press.log, from which the input of the case can be written.

set rewrites the frames, input, hold, note and screenshot checks of a case (the other checks stay) and adds a
[[case.history]] entry. The screenshots are expected/<case>_NNNNN.png when the case shares its dir, and
expected/frame_NNNNN.png otherwise; screenshots of the case that are no longer checked are deleted. Write the
expected data with romtest.py run --update afterwards.

The outputs go to packages/fnesemu_core/.dart_tool/romtool/.
"""
import argparse
import datetime
import json
import re
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import romtest  # noqa: E402

OUT = romtest.CORE_PKG / ".dart_tool" / "romtool"
SERVER = OUT / "server.json"


def find_case(root: Path, case_id: str) -> romtest.Case:
    cases = romtest.select(romtest.load_cases(root), [case_id])
    if len(cases) != 1:
        sys.exit(f"no case {case_id} in {root}")
    return cases[0]


def harness_command(case: romtest.Case, exe: Path):
    """The harness command without frames, output and input."""
    cmd = [str(exe)]
    if case.harness() == "core_harness.dart":
        cmd.append(case.spec.get("core", case.core))
    cmd += [str(case.path(f)) for f in case.spec["files"]]
    cmd += [str(case.path(a)) if a.startswith(("./", "../")) else a for a in case.spec.get("args", [])]
    return cmd


def sheet(paths, dest: Path, cols=6, scale=0.5):
    """Tiles the screenshots with their frame numbers."""
    from PIL import Image, ImageDraw
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
    exe = romtest.compile_harnesses([case])[case.harness()]
    spec = json.loads(a.input) if a.input is not None else case.spec.get("input", [])
    hold = a.hold if a.hold is not None else case.spec.get("hold", 10)
    out = OUT / "shoot" / case.name
    subprocess.run(["rm", "-rf", str(out)])
    out.mkdir(parents=True)
    cmd = harness_command(case, exe) + ["-f", str(a.frames), "-e", str(a.every), "-o", str(out)]
    if case.harness() == "core_harness.dart":
        cmd += ["-s", str(a.start)]
    for f, b, n in romtest.parse_input(spec, hold):
        cmd += ["-p", f"{f}:{b}:{n}"]
    r = subprocess.run(cmd, cwd=romtest.CORE_PKG, capture_output=True, text=True)
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
    return OUT / "serve" / json.loads(SERVER.read_text())["case"]


def serve(a):
    case = find_case(a.root, a.case)
    if case.harness() != "core_harness.dart":
        sys.exit(f"{case.id} uses {case.harness()}, which has no server mode")
    exe = romtest.compile_harnesses([case])[case.harness()]
    d = OUT / "serve" / case.name
    subprocess.run(["rm", "-rf", str(d)])
    d.mkdir(parents=True)
    log = d / "server.log"
    cmd = harness_command(case, exe) + ["-H", str(case.spec.get("hold", 10)), "-w", "--serve", "0"]
    subprocess.Popen(cmd, cwd=romtest.CORE_PKG, stdout=open(log, "w"), stderr=subprocess.STDOUT,
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
    SERVER.write_text(json.dumps({"case": case.name, "port": port, "hold": case.spec.get("hold", 10)}))
    print(f"serving {case.id} on port {port}")


def run(a):
    if a.every is None:
        print(request("/run", frames=a.frames))
        return
    d = server_dir() / f"run_{time.time_ns()}"
    r = request("/run", frames=a.frames, every=a.every, dir=str(d))
    pngs = sorted(d.glob("frame_*.png"))
    if pngs:
        sheet(pngs, server_dir() / "sheet.png", a.cols)
    print(r)


def press(a):
    frame = request("/state")["frame"]
    hold = json.loads(SERVER.read_text())["hold"]
    for f, b, n in romtest.parse_input(a.sequence, hold):
        r = request("/press", button=b, at=frame + 1 + f, frames=n)
        if "error" in r:
            sys.exit(r["error"])
    with open(server_dir() / "press.log", "a") as log:
        log.write(f"@{frame + 1} {a.sequence}\n")
    print(f"scheduled from frame {frame + 1}")


def shot(a):
    print(request("/shot", path=str(server_dir() / f"{a.name}.png")))


def state(a):
    r = request("/state")
    print(r["frame"], hex(r.get("pc", 0)))


def stop(a):
    print(request("/quit"))


def set_case(a):
    case = find_case(a.root, a.case)
    path = a.root / case.core / "roms.toml"
    blocks = path.read_text().split("[[case]]")
    idx = next(i for i, b in enumerate(blocks) if re.search(rf'^name = "{re.escape(case.name)}"$', b, re.M))
    block = blocks[idx]
    shots = [int(x) for x in a.shots.split(",")]
    prefix = f"{case.name}_" if "dir" in case.spec else "frame_"

    def text(s):
        return json.dumps(s, ensure_ascii=False)

    def set_line(block, key, value):
        pat = re.compile(rf"^{key} = .*$", re.M)
        line = f"{key} = {value}"
        if pat.search(block):
            return pat.sub(lambda m: line, block, count=1)
        return re.sub(r"^(frames = .*)$", lambda m: m.group(1) + "\n" + line, block, count=1, flags=re.M)

    block = set_line(block, "frames", str(a.frames))
    if a.input is not None:
        spec = json.loads(a.input)
        romtest.parse_input(spec, 10)  # rejects input that cannot be read
        items = spec if isinstance(spec, list) else [spec]
        block = set_line(block, "input", "[" + ", ".join(
            text(x) if isinstance(x, str) else "[" + ", ".join(text(v) for v in x) + "]" for x in items) + "]")
    if a.hold is not None:
        block = set_line(block, "hold", str(a.hold))
    if a.note is not None:
        block = set_line(block, "note", text(a.note))
    checks = [f'{{ frame = {f}, expected = "expected/{prefix}{f:05d}.png" }}' for f in shots]
    for c in case.checks():
        if "frame" not in c:
            checks.append("{ " + ", ".join(f"{k} = {text(v)}" for k, v in c.items()) + " }")
    block = set_line(block, "checks", "[" + ", ".join(checks) + "]")
    if a.history is not None:
        today = datetime.date.today().isoformat()
        block = block.rstrip("\n") + f'\n\n[[case.history]]\ndate = "{today}"\ntext = {text(a.history)}\n\n'
    blocks[idx] = block
    new = "[[case]]".join(blocks)
    tomllib.loads(new)
    path.write_text(new)
    for p in (case.dir / "expected").glob(f"{prefix}*.png"):
        if p.stem[len(prefix):].isdigit() and int(p.stem[len(prefix):]) not in shots:
            p.unlink()
    print(f"updated {case.id}; run romtest.py run {case.id} --update")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=romtest.DEFAULT_ROOT, help="the ROM tree (default: %(default)s)")
    sub = ap.add_subparsers(dest="action", required=True)

    p = sub.add_parser("shoot", help="run a case and tile its screenshots")
    p.add_argument("case")
    p.add_argument("frames", type=int)
    p.add_argument("every", type=int)
    p.add_argument("--input", help="the input as JSON, in the roms.toml syntax")
    p.add_argument("--hold", type=int)
    p.add_argument("--start", type=int, default=0, help="the first frame to tile")
    p.add_argument("--cols", type=int, default=6)
    p.add_argument("--scale", type=float, default=0.5)
    p.set_defaults(func=shoot)

    p = sub.add_parser("serve", help="start the harness server for a case")
    p.add_argument("case")
    p.set_defaults(func=serve)
    p = sub.add_parser("run", help="advance the server")
    p.add_argument("frames", type=int)
    p.add_argument("--every", type=int)
    p.add_argument("--cols", type=int, default=6)
    p.set_defaults(func=run)
    p = sub.add_parser("press", help="schedule an input sequence from the next frame")
    p.add_argument("sequence")
    p.set_defaults(func=press)
    p = sub.add_parser("shot", help="save the current screen")
    p.add_argument("name")
    p.set_defaults(func=shot)
    sub.add_parser("state", help="print the frame and the program counter").set_defaults(func=state)
    sub.add_parser("stop", help="stop the server").set_defaults(func=stop)

    p = sub.add_parser("set", help="rewrite the frames, input and screenshots of a case")
    p.add_argument("case")
    p.add_argument("--frames", type=int, required=True)
    p.add_argument("--shots", required=True, help="the frames to check, comma separated")
    p.add_argument("--input", help="the input as JSON, in the roms.toml syntax")
    p.add_argument("--hold", type=int)
    p.add_argument("--note")
    p.add_argument("--history", help="a [[case.history]] entry")
    p.set_defaults(func=set_case)

    a = ap.parse_args(argv)
    a.root = a.root.resolve()
    if not a.root.is_dir():
        sys.exit(f"no ROM tree: {a.root}")
    a.func(a)


if __name__ == "__main__":
    main()
