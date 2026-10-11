// headless GB harness: runs a rom (.gb/.zip) and dumps frames as png
//
// usage: dart run tool/gb_harness.dart <rom> [options]
//   -f, --frames N   number of frames to run (default: 600)
//   -e, --every N    save a png every N frames (default: 60)
//   -o, --out DIR    output directory (default: /tmp/gb_harness)
//   -p, --press F:B  press button B (index or name) at frame F (repeatable)
//   -H, --hold N     frames to hold a pressed button (default: 10)
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:fnesemu_core/src/core/gb/gb.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  int frames = 600;
  int every = 60;
  String outDir = "/tmp/gb_harness";
  final presses = <(int, String)>[];
  int holdFrames = 10;
  final files = <String>[];

  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "-f" || "--frames":
        frames = int.parse(args[++i]);
      case "-e" || "--every":
        every = int.parse(args[++i]);
      case "-o" || "--out":
        outDir = args[++i];
      case "-H" || "--hold":
        holdFrames = int.parse(args[++i]);
      case "-p" || "--press":
        final p = args[++i].split(":");
        presses.add((int.parse(p[0]), p[1]));
      default:
        files.add(args[i]);
    }
  }

  if (files.isEmpty) {
    print("usage: gb_harness <rom> [-f frames] [-e every] [-o dir] [-p F:B]");
    exit(1);
  }

  Directory(outDir).createSync(recursive: true);

  final gb = Gb()..setSram(Sram());
  gb.setRom(_loadRom(files[0]));
  print("${gb.bus.cart.header}");

  final buttons = gb.buttons;
  final pressList = presses.map((p) {
    final idx = int.tryParse(p.$2) ??
        buttons.indexWhere((b) => b.name.toLowerCase() == p.$2.toLowerCase());
    if (idx < 0 || idx >= buttons.length) {
      throw "unknown button: ${p.$2} (${buttons.map((b) => b.name).join(",")})";
    }
    return (p.$1, idx);
  }).toList();

  final sw = Stopwatch()..start();
  int frame = 0;

  while (frame < frames) {
    final r = gb.exec(false);
    if (r.stopped) {
      print("stopped at frame $frame\n${gb.dump()}");
      _savePng(gb.imageBuffer(), "$outDir/stopped.png");
      exit(2);
    }
    if (gb.ppu.frames == frame) continue;
    frame = gb.ppu.frames;

    for (final (f, b) in pressList) {
      if (frame == f) gb.padDown(0, buttons[b]);
      if (frame == f + holdFrames) gb.padUp(0, buttons[b]);
    }

    if (frame % every == 0) {
      final path = "$outDir/frame_${frame.toString().padLeft(5, "0")}.png";
      _savePng(gb.imageBuffer(), path);
      print("frame $frame "
          "(${(sw.elapsedMicroseconds / frame / 1000).toStringAsFixed(2)} ms/frame) "
          "pc:${gb.cpu.pc.toRadixString(16)} -> $path");
    }
  }

  File("$outDir/state.txt").writeAsStringSync(gb.dump());
  print(gb.dump());
}

Uint8List _loadRom(String path) {
  final bytes = File(path).readAsBytesSync();
  if (!path.toLowerCase().endsWith(".zip")) return bytes;

  final archive = ZipDecoder().decodeBytes(bytes);
  final entry = archive.files.firstWhere(
      (f) => f.isFile && RegExp(r"\.gbc?$", caseSensitive: false).hasMatch(f.name));
  return Uint8List.fromList(entry.content as List<int>);
}

void _savePng(ImageBuffer buf, String path) {
  if (buf.width == 0) return;
  final image = img.Image.fromBytes(
      width: buf.width,
      height: buf.height,
      bytes: buf.buffer.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba);
  File(path).writeAsBytesSync(img.encodePng(image));
}
