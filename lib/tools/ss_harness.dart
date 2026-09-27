// headless SS harness: runs BIOS (+ disc) and dumps frames as png
//
// usage: dart run lib/tools/ss_harness.dart <bios> [disc] [options]
//   -f, --frames N   number of frames to run (default: 600)
//   -e, --every N    save a png every N frames (default: 60)
//   -o, --out DIR    output directory (default: /tmp/ss_harness)
//   -l, --log-cd     log CD block commands
//   -p, --press F:B  press button B (index) at frame F (repeatable)
//   -H, --hold N     frames to hold a pressed button (default: 10)
import 'dart:io';

import 'package:fnesemu/core/ss/ss.dart';
import 'package:fnesemu/core/sram.dart';
import 'package:fnesemu/core/types.dart';
import 'package:fnesemu/disc/loader.dart';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  int frames = 600;
  int every = 60;
  String outDir = "/tmp/ss_harness";
  final presses = <(int, int)>[];
  bool logCd = false;
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
      case "-l" || "--log-cd":
        logCd = true;
      case "-p" || "--press":
        final p = args[++i].split(":");
        presses.add((int.parse(p[0]), int.parse(p[1])));
      default:
        files.add(args[i]);
    }
  }

  if (files.isEmpty) {
    print("usage: ss_harness <bios> [disc] [-f frames] [-e every] [-o dir]");
    exit(1);
  }

  Directory(outDir).createSync(recursive: true);

  final ss = Ss()..setSram(Sram());
  ss.setRom(File(files[0]).readAsBytesSync());
  if (files.length > 1) {
    ss.setDisc(DiscLoader.load(files[1]));
  }
  ss.reset();
  ss.cdblock.log = logCd;

  final sw = Stopwatch()..start();
  int lines = 0;
  int frame = 0;

  while (frame < frames) {
    final r = ss.exec(false);
    if (r.stopped) {
      print("stopped at frame $frame\n${ss.dump()}");
      _savePng(ss.imageBuffer(), "$outDir/stopped.png");
      exit(2);
    }
    if (!r.scanlineRendered) continue;

    if (++lines < ss.scanlinesInFrame) continue;
    lines = 0;
    frame++;

    for (final (f, b) in presses) {
      if (frame == f) ss.padDown(0, ss.buttons[b]);
      if (frame == f + holdFrames) ss.padUp(0, ss.buttons[b]);
    }

    if (frame % every == 0) {
      final path = "$outDir/frame_${frame.toString().padLeft(5, "0")}.png";
      _savePng(ss.imageBuffer(), path);
      print("frame $frame (${(sw.elapsedMilliseconds / frame).toStringAsFixed(1)} ms/frame) "
          "pc:${ss.master.pc.toRadixString(16)} "
          "slave:${ss.slave.pc.toRadixString(16)} "
          "68k:${ss.scsp.cpu.pc.toRadixString(16)} -> $path");
      print("  ${ss.cdblock.dump()}");
    }
  }

  File("$outDir/state.txt").writeAsStringSync(ss.dump());
  print(ss.dump());
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
