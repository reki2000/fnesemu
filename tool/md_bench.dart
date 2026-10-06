// benchmark of the md core (also md cdrom / 32x): runs a rom for N frames
// the same way as lib/tools/core_harness.dart and prints the speed and a hash
// of every frame image and of the audio output, to check that an optimization
// does not change the output.
//
// usage: dart run tool/md_bench.dart <md|mdcd|32x> <rom|bios> [disc]
//          [-f frames] [-p F:B]... [-H hold] [-3 main,master,slave]
//          [-l hashfile]   (writes the per-frame hashes)
//          [-n]            (no hashes: only the speed)
//          [-r]            (runs frames by FrameRunner.runFrame, not exec)
//
// AOT: dart compile exe tool/md_bench.dart -o md_bench && ./md_bench ...
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu/cdrom/async_cdrom_drive.dart';
import 'package:fnesemu/cdrom/disc_source_local.dart';
import 'package:fnesemu/core/core.dart';
import 'package:fnesemu/core/md/md.dart';

Future<void> main(List<String> args) async {
  final files = <String>[];
  int frames = 1200;
  int hold = 12;
  String? hashFile;
  bool noHash = false;
  bool useRunFrame = false;
  List<String>? bootRoms;
  final presses = <(int, String)>[];
  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "-f":
        frames = int.parse(args[++i]);
      case "-H":
        hold = int.parse(args[++i]);
      case "-n":
        noHash = true;
      case "-r":
        useRunFrame = true;
      case "-l":
        hashFile = args[++i];
      case "-3":
        bootRoms = args[++i].split(",");
      case "-p":
        final p = args[++i].split(":");
        presses.add((int.parse(p[0]), p[1]));
      default:
        files.add(args[i]);
    }
  }

  final kind = files[0];
  final core = switch (kind) {
    "md" => Md(),
    "mdcd" => Md(cdBoot: true),
    "32x" => Md(expansionBoot: true),
    _ => throw "unknown core: $kind",
  };

  AsyncCdromDrive? drive;
  if (files.length > 2) {
    drive = AsyncCdromDrive();
    await drive.insert(discSourceFromPath(files[2]));
  }
  if (kind == "mdcd" && drive != null) core.setCdromDrive(drive);
  if (bootRoms != null) {
    core.setExpansionBootRoms(
        main: File(bootRoms[0]).readAsBytesSync(),
        master: File(bootRoms[1]).readAsBytesSync(),
        slave: File(bootRoms[2]).readAsBytesSync());
  }
  core.setRom(_loadRom(files[1]));
  if (kind != "mdcd" && kind != "32x") core.reset();

  // the vdp fills vram / cram with random values at reset: refill them with a
  // fixed seed so that the frames are the same in every run
  final rand = Random(0);
  for (int i = 0; i < core.vdp.vram.length; i++) {
    core.vdp.vram[i] = rand.nextInt(0x10000);
  }
  for (int i = 0; i < core.vdp.cram.length; i++) {
    core.vdp.cram[i] = rand.nextInt(0x200);
  }

  final buttons = core.buttons;
  final pressList = presses.map((p) {
    final idx = buttons
        .indexWhere((b) => b.name.toLowerCase() == p.$2.toLowerCase());
    if (idx < 0) throw "unknown button: ${p.$2}";
    return (p.$1, idx);
  }).toList();

  int audioHash = 0x811c9dc5;
  int audioSamples = 0;
  core.onAudio((buf) {
    if (noHash) return;
    for (final s in buf.buffer) {
      final v = (s.clamp(-1.0, 1.0) * 32767).round() & 0xffff;
      audioHash = ((audioHash ^ v) * 0x01000193) & 0xffffffff;
    }
    audioSamples += buf.buffer.length;
  });

  final frameHashes = <int>[];
  int allHash = 0;
  final sw = Stopwatch();
  int lines = 0;
  int frame = 0;

  final runner = useRunFrame ? core as FrameRunner : null;
  final cpu0 = _cpuMs();
  sw.start();
  while (frame < frames) {
    if (runner != null) {
      if (runner.runFrame(core.scanlinesInFrame).stopped) {
        print("stopped at frame $frame");
        exit(2);
      }
    } else {
      final r = core.exec(false);
      if (r.stopped) {
        print("stopped at frame $frame");
        exit(2);
      }
      if (!r.scanlineRendered) continue;
      if (++lines < core.scanlinesInFrame) continue;
      lines = 0;
    }
    frame++;
    sw.stop();
    await drive?.settle();
    for (final (f, b) in pressList) {
      if (frame == f) core.padDown(0, buttons[b]);
      if (frame == f + hold) core.padUp(0, buttons[b]);
    }
    if (noHash) {
      sw.start();
      continue;
    }
    final h = _hash(core.imageBuffer().buffer);
    frameHashes.add(h);
    allHash = ((allHash * 31) ^ h) & 0xffffffff;
    sw.start();
  }
  sw.stop();
  final cpuMs = _cpuMs() - cpu0;

  final ms = sw.elapsedMicroseconds / 1000;
  print("frames:$frames time:${ms.toStringAsFixed(0)}ms "
      "${(ms / frames).toStringAsFixed(3)}ms/frame "
      "${(frames * 1000 / ms).toStringAsFixed(1)}fps "
      "cpu:${(cpuMs / frames).toStringAsFixed(3)}ms/frame "
      "video:${allHash.toRadixString(16)} "
      "audio:${audioHash.toRadixString(16)}/$audioSamples");
  if (hashFile != null) {
    File(hashFile).writeAsStringSync(frameHashes
        .asMap()
        .entries
        .map((e) => "${e.key + 1} ${e.value.toRadixString(16)}")
        .join("\n"));
  }
  exit(0);
}

// user + system cpu time of this process
int _cpuMs() {
  final f = File("/proc/self/stat").readAsStringSync();
  final fields = f.substring(f.lastIndexOf(")") + 2).split(" ");
  return (int.parse(fields[11]) + int.parse(fields[12])) * 10; // 100Hz ticks
}

int _hash(Uint8List b) {
  final w = b.buffer.asUint32List(b.offsetInBytes, b.lengthInBytes >> 2);
  int h = 0x811c9dc5;
  for (int i = 0; i < w.length; i++) {
    h = ((h ^ w[i]) * 0x01000193) & 0xffffffff;
  }
  return h;
}

Uint8List _loadRom(String path) {
  final bytes = File(path).readAsBytesSync();
  if (!path.toLowerCase().endsWith(".zip")) return bytes;
  final archive = ZipDecoder().decodeBytes(bytes);
  final f = archive.files.firstWhere((f) => f.isFile);
  return Uint8List.fromList(f.content as List<int>);
}
