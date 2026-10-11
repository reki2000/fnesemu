// speed benchmark of the pce core (pce / sgx / pce cdrom).
//
// runs the core like the gui does (exec until a scanline is rendered, one
// imageBuffer() per frame) and reports the time per frame. with -c it also
// prints a checksum of every frame image and of the audio output, to check
// that an optimization does not change the output.
//
// usage: dart run tool/pce_bench.dart <rom|system card> [disc.cue]
//          [-f frames] [-p frame:button ...] [-H hold] [-c] [-r]
// -r runs each frame with runFrame() (as the gui does without the debugger)
// instead of exec() per instruction.
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:fnesemu_core/src/sram.dart';

import 'cdrom_drive.dart';
import 'local_disc.dart';

Future<void> main(List<String> args) async {
  int frames = 1200;
  int hold = 12;
  bool checksum = false;
  bool runFrame = false;
  final presses = <(int, String)>[];
  final files = <String>[];
  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "-f":
        frames = int.parse(args[++i]);
      case "-H":
        hold = int.parse(args[++i]);
      case "-c":
        checksum = true;
      case "-r":
        runFrame = true;
      case "-p":
        final s = args[++i].split(":");
        presses.add((int.parse(s[0]), s[1]));
      default:
        files.add(args[i]);
    }
  }

  final core = Pce();
  core.setSram(Sram());
  core.setRom(File(files[0]).readAsBytesSync());
  SimpleCdromDrive? drive;
  if (files.length > 1) {
    drive = SimpleCdromDrive();
    await drive.insert(localDisc(files[1]));
    core.setCdromDrive(drive);
  }
  core.reset();

  final buttons = core.buttons;
  final pressList = presses
      .map((p) => (
            p.$1,
            buttons.firstWhere(
                (b) => b.name.toLowerCase() == p.$2.toLowerCase())
          ))
      .toList();

  // fnv-1a over the raw bytes
  int hash = 0xcbf29ce484222325;
  int audioHash = 0xcbf29ce484222325;
  int samples = 0;
  int mix(int h, Uint8List b) {
    for (final v in b) {
      h = ((h ^ v) * 0x100000001b3) & 0xffffffffffffffff;
    }
    return h;
  }

  core.onAudio((buf) {
    samples += buf.buffer.length;
    if (checksum) {
      audioHash = mix(audioHash, buf.buffer.buffer.asUint8List(
          buf.buffer.offsetInBytes, buf.buffer.lengthInBytes));
    }
  });

  final sw = Stopwatch()..start();
  int lines = 0;
  int frame = 0;
  while (frame < frames) {
    if (runFrame) {
      if (core.runFrame(core.scanlinesInFrame).stopped) {
        throw "stopped at frame $frame";
      }
    } else {
      final r = core.exec(false);
      if (r.stopped) throw "stopped at frame $frame";
      if (!r.scanlineRendered) continue;
      if (++lines < core.scanlinesInFrame) continue;
      lines = 0;
    }
    frame++;
    final image = core.imageBuffer();
    if (checksum) hash = mix(hash, image.buffer);
    if (drive != null) {
      sw.stop();
      await drive.settle();
      sw.start();
    }
    for (final (f, b) in pressList) {
      if (frame == f) core.padDown(0, b);
      if (frame == f + hold) core.padUp(0, b);
    }
  }
  sw.stop();

  final ms = sw.elapsedMicroseconds / 1000;
  print("frames:$frames time:${ms.toStringAsFixed(0)}ms "
      "${(ms / frames).toStringAsFixed(3)}ms/frame "
      "${(frames * 1000 / ms).toStringAsFixed(1)}fps samples:$samples"
      "${checksum ? " image:${hash.toRadixString(16)} audio:${audioHash.toRadixString(16)}" : ""}");
}
