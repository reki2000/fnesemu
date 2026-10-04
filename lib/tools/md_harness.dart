// Headless harness for the MD core.
//
// Runs a ROM up to a given frame and writes the screen (and optionally
// debug views) as PNG files.
//
// usage:
//   dart run lib/tools/md_harness.dart <rom> [options]
//
// options:
//   -f, --frames N        number of frames to run (default: 60)
//   -o, --out DIR         output directory (default: out/md_harness)
//   -e, --every N         also save a screenshot every N frames (0: last only)
//   -p, --press SPEC      pad input: "<button>@<frame>[+<len>]", repeatable.
//                         e.g. "Start@300+5" presses Start at frame 300 for 5 frames
//   -s, --scale N         integer scale factor of output png (default: 1)
//   -d, --debug           also dump plane/vram/cram images and vdp state
//                         at the last frame

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../core/md/md.dart';
import '../core/pad_button.dart';
import '../core/types.dart';

class _Press {
  final PadButton button;
  final int from;
  final int to; // exclusive

  _Press(this.button, this.from, this.to);
}

void _usage([String? error]) {
  if (error != null) stderr.writeln("error: $error");
  stderr.writeln(
      "usage: dart run lib/tools/md_harness.dart <rom> [-f frames] [-o outdir] [-e every] [-p Button@frame[+len]] [-s scale] [-d]");
  exit(1);
}

void main(List<String> args) {
  String? romPath;
  var frames = 60;
  var outDir = "out/md_harness";
  var every = 0;
  var scale = 1;
  var debug = false;
  final pressSpecs = <String>[];

  for (int i = 0; i < args.length; i++) {
    String next() => i + 1 < args.length ? args[++i] : _usageNull();

    switch (args[i]) {
      case "-f" || "--frames":
        frames = int.parse(next());
      case "-o" || "--out":
        outDir = next();
      case "-e" || "--every":
        every = int.parse(next());
      case "-p" || "--press":
        pressSpecs.add(next());
      case "-s" || "--scale":
        scale = int.parse(next());
      case "-d" || "--debug":
        debug = true;
      case "-h" || "--help":
        _usage();
      default:
        if (args[i].startsWith("-") || romPath != null) {
          _usage("unknown argument: ${args[i]}");
        }
        romPath = args[i];
    }
  }

  if (romPath == null) _usage("rom path is required");

  final md = Md();
  final presses = pressSpecs.map((s) => _parsePress(s, md.buttons)).toList();

  md.setRom(File(romPath!).readAsBytesSync());
  Directory(outDir).createSync(recursive: true);

  final name = romPath.split(Platform.pathSeparator).last.split(".").first;
  final sw = Stopwatch()..start();

  var scanlines = 0;
  for (int frame = 1; frame <= frames; frame++) {
    // pad input for this frame
    for (final p in presses) {
      if (frame == p.from) md.padDown(0, p.button);
      if (frame == p.to) md.padUp(0, p.button);
    }

    // run until one frame worth of scanlines is rendered
    final target = frame * md.scanlinesInFrame;
    while (scanlines < target) {
      final r = md.exec(false);
      if (r.stopped) {
        stderr.writeln("core stopped at frame $frame\n${md.dump()}");
        _savePng(md.imageBuffer(), "$outDir/${name}_stopped.png", scale);
        exit(2);
      }
      if (r.scanlineRendered) scanlines++;
    }

    if (frame == frames || (every > 0 && frame % every == 0)) {
      final path = "$outDir/${name}_${frame.toString().padLeft(5, "0")}.png";
      _savePng(md.imageBuffer(), path, scale);
      print("frame $frame -> $path");
    }
  }

  print("ran $frames frames in ${sw.elapsedMilliseconds}ms");

  if (debug) {
    File("$outDir/${name}_state.txt").writeAsStringSync(
        "${md.dump()}\n\n[sprites]\n${md.spriteInfo().join("\n")}\n");
    _savePng(md.renderBg(), "$outDir/${name}_bg.png", 1);
    _savePng(md.renderVram(false, 0), "$outDir/${name}_vram.png", 1);
    _savePng(md.renderColorTable(0), "$outDir/${name}_cram.png", 4);
    print("debug dump -> $outDir/${name}_{state.txt,bg,vram,cram.png}");
  }
}

Never _usageNull() {
  _usage("missing option value");
  throw StateError("unreachable");
}

_Press _parsePress(String spec, List<PadButton> buttons) {
  final m = RegExp(r"^(\w+)@(\d+)(?:\+(\d+))?$").firstMatch(spec);
  if (m == null) _usage("invalid press spec: $spec");

  final name = m!.group(1)!.toLowerCase();
  final button = buttons.firstWhere((b) => b.name.toLowerCase() == name,
      orElse: () => _usageNull());
  final from = int.parse(m.group(2)!);
  final len = int.parse(m.group(3) ?? "1");

  return _Press(button, from, from + len);
}

/// saves an RGBA8888 image buffer as png
void _savePng(ImageBuffer buf, String path, int scale) {
  if (buf.width == 0 || buf.height == 0) return;

  final bytes = Uint8List.sublistView(buf.buffer, 0, buf.width * buf.height * 4);
  var image = img.Image.fromBytes(
      width: buf.width,
      height: buf.height,
      bytes: bytes.buffer,
      bytesOffset: bytes.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba);

  if (scale > 1) {
    image = img.copyResize(image,
        width: buf.width * scale,
        height: buf.height * scale,
        interpolation: img.Interpolation.nearest);
  }

  File(path).writeAsBytesSync(img.encodePng(image));
}
