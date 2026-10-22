#!/usr/bin/env python3
"""Tools for writing the cases of a ROM tree: try inputs, pick the frames and record them in roms.toml.

  scripts/romtool.py shoot <core>/<case> N --every E [--start S] [--input SEQ] [--cols C] [--scale X]
  scripts/romtool.py buttons [<core>/<case>]
  scripts/romtool.py serve <core>/<case>
  scripts/romtool.py run N [--every E] [--cols C] [--scale X]
  scripts/romtool.py press SEQ
  scripts/romtool.py input
  scripts/romtool.py shot [NAME]
  scripts/romtool.py state
  scripts/romtool.py stop
  scripts/romtool.py set <core>/<case> --frames N --shots F1,F2,... [--input SEQ] [--note TEXT] [--history TEXT]

Every command takes --root DIR like romtest.py (default: packages/fnesemu_core/test/roms). SEQ is an input
sequence in the syntax of the input of roms.toml (see romtest.py); @F is always an absolute frame.

shoot runs the case for N frames (with --input in place of its input) and tiles the screenshots saved every E
frames from frame S, with their frame numbers, into sheet.png. buttons prints the button names of the case (or of
the served case) as they are written in a sequence.

serve starts core_harness serve for the case in the background; run, press, shot and state control it, and
stop ends it. run advances N frames (with --every, it saves the screenshots of the frames that are multiples of E
and tiles them into sheet.png). press adds the presses of SEQ, read with the cursor at the next frame, and logs it
in press.log. input prints the input of the logged presses (one after another, or in parallel where they overlap),
e.g. for set --input "$(scripts/romtool.py input)".

set rewrites the frames, input, note and screenshot checks of a case (the other checks stay) and adds a
[[case.history]] entry, which replaces the last entry when that has the date of today. The harness reads the
input first. The screenshots are expected/<case>_NNNNN.png when the case shares its dir, and
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


def harness() -> Path:
    return romtest.compile_harness()


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
    cmd = case.base_command(harness(), "run") + ["-f", str(a.frames), "-e", str(a.every), "-o", str(out),
                                                 "-s", str(a.start)]
    if seq:
        cmd += ["--input", seq]
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


def buttons(a):
    if a.case is None:
        names = request("/buttons")["buttons"]
    else:
        case = find_case(a.root, a.case)
        r = subprocess.run(case.base_command(harness(), "buttons"), cwd=romtest.CORE_PKG,
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(r.stderr[-1000:] or r.stdout[-1000:])
        names = json.loads(r.stdout)
    print(" ".join(quote_button(n) for n in names if n))


def quote_button(name: str) -> str:
    """The name as written in a sequence (the rule of quoteButton in tool/input_sequence.dart)."""
    return f'"{name}"' if any(c in '@_:+[]*()|" \t\n\r' for c in name) else name


def serve(a):
    case = find_case(a.root, a.case)
    d = OUT / "serve" / case.name
    subprocess.run(["rm", "-rf", str(d)])
    d.mkdir(parents=True)
    log = d / "server.log"
    cmd = case.base_command(harness(), "serve") + ["--port", "0"]
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
    SERVER.write_text(json.dumps({"case": case.name, "port": port}))
    print(f"serving {case.id} on port {port}")


def run(a):
    if a.every is None:
        print(json.dumps(request("/run", frames=a.frames)))
        return
    d = server_dir() / f"run_{time.time_ns()}"
    r = request("/run", frames=a.frames, every=a.every, dir=str(d))
    pngs = sorted(d.glob("frame_*.png"))
    if pngs:
        sheet(pngs, server_dir() / "sheet.png", a.cols, a.scale)
    print(json.dumps(r))


def press(a):
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


def input_(a):
    print(logged_input())


def shot(a):
    name = a.name or f"frame_{request('/state')['frame']:05d}"
    print(json.dumps(request("/shot", path=str(server_dir() / f"{name}.png"))))


def state(a):
    r = request("/state")
    print(json.dumps({"frame": r["frame"], "pc": hex(r.get("pc", 0))}))


def stop(a):
    print(json.dumps(request("/quit")))


def set_case(a):
    case = find_case(a.root, a.case)
    path = a.root / case.core / "roms.toml"
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
        if a.input and (err := case.check_input(harness())):
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
    print(f"updated {case.id}; run romtest.py run {case.id} --update")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=romtest.DEFAULT_ROOT, help="the ROM tree (default: %(default)s)")
    sub = ap.add_subparsers(dest="action", required=True)

    p = sub.add_parser("shoot", help="run a case and tile its screenshots")
    p.add_argument("case")
    p.add_argument("frames", type=int)
    p.add_argument("--every", type=int, required=True)
    p.add_argument("--start", type=int, default=0, help="the first frame to tile")
    p.add_argument("--input", help="the input sequence in place of the input of the case")
    p.add_argument("--cols", type=int, help="screenshots in a row (default: up to 12)")
    p.add_argument("--scale", type=float, default=0.5)
    p.set_defaults(func=shoot)

    p = sub.add_parser("buttons", help="print the button names of a case or of the served case")
    p.add_argument("case", nargs="?")
    p.set_defaults(func=buttons)
    p = sub.add_parser("serve", help="start the harness server for a case")
    p.add_argument("case")
    p.set_defaults(func=serve)
    p = sub.add_parser("run", help="advance the server")
    p.add_argument("frames", type=int)
    p.add_argument("--every", type=int)
    p.add_argument("--cols", type=int, help="screenshots in a row (default: up to 12)")
    p.add_argument("--scale", type=float, default=0.5)
    p.set_defaults(func=run)
    p = sub.add_parser("press", help="add the presses of an input sequence from the next frame")
    p.add_argument("seq")
    p.set_defaults(func=press)
    sub.add_parser("input", help="print the input of the presses so far, for set --input").set_defaults(func=input_)
    p = sub.add_parser("shot", help="save the current screen")
    p.add_argument("name", nargs="?", help="the file name without .png (default: frame_NNNNN)")
    p.set_defaults(func=shot)
    sub.add_parser("state", help="print the frame and the program counter").set_defaults(func=state)
    sub.add_parser("stop", help="stop the server").set_defaults(func=stop)

    p = sub.add_parser("set", help="rewrite the frames, input and screenshots of a case")
    p.add_argument("case")
    p.add_argument("--frames", type=int, required=True)
    p.add_argument("--shots", required=True, help="the frames to check, comma separated")
    p.add_argument("--input", help="the input sequence")
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
