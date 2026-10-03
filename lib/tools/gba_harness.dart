// headless GBA harness: runs a cartridge (.gba or .zip) and dumps frames as png
//
// usage: dart run lib/tools/gba_harness.dart <rom> [options]
//   -b, --bios FILE  boot from this BIOS image (default: HLE boot)
//   -f, --frames N   number of frames to run (default: 600)
//   -e, --every N    save a png every N frames (default: 60)
//   -o, --out DIR    output directory (default: /tmp/gba_harness)
//   -p, --press F:B  press button B (index) at frame F (repeatable)
//                    0:up 1:down 2:left 3:right 4:select 5:start 6:A 7:B 8:L 9:R
//   -H, --hold N     frames to hold a pressed button (default: 10)
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu/core/gba/gba.dart';
import 'package:fnesemu/core/sram.dart';
import 'package:fnesemu/core/types.dart';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  int frames = 600;
  int every = 60;
  String outDir = "/tmp/gba_harness";
  String? bios;
  final presses = <(int, int)>[];
  int holdFrames = 10;
  final files = <String>[];

  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "-b" || "--bios":
        bios = args[++i];
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
        presses.add((int.parse(p[0]), int.parse(p[1])));
      default:
        files.add(args[i]);
    }
  }

  if (files.isEmpty) {
    print("usage: gba_harness <rom> [-b bios] [-f frames] [-e every] [-o dir]");
    exit(1);
  }

  Directory(outDir).createSync(recursive: true);

  if (bios != null) Gba.biosImage = File(bios).readAsBytesSync();

  final gba = Gba()..setSram(Sram());
  int audioSamples = 0;
  double audioPeak = 0;
  gba.onAudio((buf) {
    audioSamples += buf.buffer.length ~/ buf.channels;
    for (final s in buf.buffer) {
      if (s.abs() > audioPeak) audioPeak = s.abs();
    }
  });
  gba.setRom(_loadRom(files[0]));
  print("title:${gba.bus.cart.title} code:${gba.bus.cart.gameCode} "
      "save:${gba.bus.cart.backup.type.name} bios:${bios != null}");

  final sw = Stopwatch()..start();
  int lines = 0;
  int frame = 0;

  while (frame < frames) {
    final r = gba.exec(false);
    if (r.stopped) {
      print("stopped at frame $frame\n${gba.dump()}");
      _savePng(gba.imageBuffer(), "$outDir/stopped.png");
      exit(2);
    }
    if (!r.scanlineRendered) continue;

    if (++lines < gba.scanlinesInFrame) continue;
    lines = 0;
    frame++;

    for (final (f, b) in presses) {
      if (frame == f) gba.padDown(0, gba.buttons[b]);
      if (frame == f + holdFrames) gba.padUp(0, gba.buttons[b]);
    }

    if (frame % every == 0) {
      final path = "$outDir/frame_${frame.toString().padLeft(5, "0")}.png";
      _savePng(gba.imageBuffer(), path);
      print("frame $frame (${(sw.elapsedMilliseconds / frame).toStringAsFixed(1)} ms/frame) "
          "pc:${gba.cpu.regs.pc.toRadixString(16)} "
          "thumb:${gba.cpu.regs.thumb} halt:${gba.bus.halted} "
          "audio:$audioSamples peak:${audioPeak.toStringAsFixed(3)} -> $path");
      audioPeak = 0;
    }
  }

  File("$outDir/state.txt").writeAsStringSync(gba.dump());
  print(gba.dump());
}

// read a .gba file, or the first .gba entry of a zip
Uint8List _loadRom(String path) {
  final data = File(path).readAsBytesSync();
  if (!path.toLowerCase().endsWith(".zip")) return data;

  for (final entry in ZipDecoder().decodeBytes(data)) {
    if (entry.name.toLowerCase().endsWith(".gba")) {
      return entry.content as Uint8List;
    }
  }
  throw Exception("no .gba file in $path");
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
