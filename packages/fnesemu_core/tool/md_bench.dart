// benchmark of the md core (also md cdrom / 32x): runs a rom for N frames
// the same way as tool/core_harness.dart and prints the speed and a hash
// of every frame image and of the audio output, to check that an optimization
// does not change the output.
//
// usage: dart run tool/md_bench.dart <md|mdcd|32x> <rom|bios> [disc]
//          [-f frames] [-i input] [-3 main,master,slave]
//          [-l hashfile]   (writes the per-frame hashes)
//          [-n]            (no hashes: only the speed)
//          [-r]            (runs frames by Core.runFrame, not exec)
//
// AOT: dart compile exe tool/md_bench.dart -o md_bench && ./md_bench ...
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu_core/src/core/md/md.dart';

import 'cdrom_drive.dart';
import 'input_sequence.dart';
import 'local_disc.dart';
import 'logging.dart';

Future<void> main(List<String> args) async {
  configureLogging();
  final files = <String>[];
  int frames = 1200;
  String? hashFile;
  bool noHash = false;
  bool useRunFrame = false;
  List<String>? bootRoms;
  var input = "";
  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "-f":
        frames = int.parse(args[++i]);
      case "-n":
        noHash = true;
      case "-r":
        useRunFrame = true;
      case "-l":
        hashFile = args[++i];
      case "-3":
        bootRoms = args[++i].split(",");
      case "-i" || "--input":
        input = args[++i];
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

  SimpleCdromDrive? drive;
  if (files.length > 2) {
    drive = SimpleCdromDrive();
    await drive.insert(localDisc(files[2]));
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
  final pad = PadPlayer(
      resolveInput(input, buttons.map((b) => b.name).toList()),
      buttons.length);

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

  final runner = useRunFrame ? core : null;
  final cpu0 = _cpuMs();
  sw.start();
  while (frame < frames) {
    if (runner != null) {
      if (runner.runFrame(core.scanlinesInFrame).stopped) {
        stdout.writeln("stopped at frame $frame");
        exit(2);
      }
    } else {
      final r = core.exec(false);
      if (r.stopped) {
        stdout.writeln("stopped at frame $frame");
        exit(2);
      }
      if (!r.scanlineRendered) continue;
      if (++lines < core.scanlinesInFrame) continue;
      lines = 0;
    }
    frame++;
    sw.stop();
    await drive?.settle();
    pad.step(frame, (b, down) {
      down ? core.padDown(0, buttons[b]) : core.padUp(0, buttons[b]);
    });
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
  stdout.writeln("frames:$frames time:${ms.toStringAsFixed(0)}ms "
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

int _hash(Uint32List w) {
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
