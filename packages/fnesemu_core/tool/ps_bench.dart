// ps1 core speed benchmark: boots the bios with a disc, fast-forwards to a
// scene, then times a fixed number of frames.
//
// usage: dart run tool/ps_bench.dart <bios> [disc.cue] [options]
//   -w N        frames to run before timing (default: 0)
//   -m N        frames to time (default: 600)
//   -p F:B      press button B at frame F (repeatable), -H N hold frames (12)
//   -l FILE     take this flock(1) lock only while timing (shared bench lock)
//   -s DIR      instead of -l: write DIR/ready.<pid> before timing and wait
//               for DIR/go (a runner times two builds side by side)
//   -x FILE     run a PS-EXE after the bios boot
//   -r          run each frame with runFrame() instead of exec() calls
//   -o DIR      write frame_NNNNN.png every -e N frames (default 300),
//               audio.pcm (s16le stereo 44.1kHz) and vram.bin (the whole vram)
//
// prints the timed ms/frame and a checksum of every frame image and of the
// audio, so that two builds can be compared for identical output. The disc
// cache of the drive runs on the emulated time (60 frames a second), so the
// result does not depend on the speed of the build.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/sram.dart';
import 'package:image/image.dart' as img;

import 'cdrom_drive.dart';
import 'local_disc.dart';
import 'ps_io.dart';

Future<void> main(List<String> args) async {
  int warm = 0, measure = 600, hold = 12, every = 300;
  String? lock, exe, outDir, syncDir;
  bool frameRunner = false;
  final presses = <(int, String)>[];
  final files = <String>[];
  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "-w":
        warm = int.parse(args[++i]);
      case "-m":
        measure = int.parse(args[++i]);
      case "-H":
        hold = int.parse(args[++i]);
      case "-e":
        every = int.parse(args[++i]);
      case "-r":
        frameRunner = true;
      case "-l":
        lock = args[++i];
      case "-s":
        syncDir = args[++i];
      case "-x":
        exe = args[++i];
      case "-o":
        outDir = args[++i];
      case "-p":
        final p = args[++i].split(":");
        presses.add((int.parse(p[0]), p[1]));
      default:
        files.add(args[i]);
    }
  }
  if (outDir != null) Directory(outDir).createSync(recursive: true);
  _syncDir = syncDir;

  int frame = 0;
  final core = createPsForTools();
  core.setSram(Sram());
  SimpleCdromDrive? drive;
  if (files.length > 1) {
    drive = SimpleCdromDrive();
    await drive.insert(localDisc(files[1]));
  }
  core.setBiosFiles([File(files[0]).readAsBytesSync()]);
  if (drive != null) core.setCdromDrive(drive);
  core.reset();
  if (exe != null) core.setRom(File(exe).readAsBytesSync());

  final buttons = core.buttons;
  final pressList = presses
      .map((p) => (
            p.$1,
            buttons
                .indexWhere((b) => b.name.toLowerCase() == p.$2.toLowerCase())
          ))
      .toList();

  final pcm = outDir != null ? BytesBuilder() : null;
  int audioHash = 0x811c9dc5;
  core.onAudio((buf) {
    for (final s in buf.buffer) {
      final v = (s.clamp(-1.0, 1.0) * 32767).round() & 0xffff;
      audioHash = ((audioHash ^ v) * 0x01000193) & 0xffffffff;
      pcm?.addByte(v & 0xff);
      pcm?.addByte(v >> 8);
    }
  });
  int imageHash = 0x811c9dc5;

  Process? locker;
  final total = Stopwatch()..start();
  final sw = Stopwatch();
  int lines = 0;
  final end = warm + measure;
  int cpu0 = 0;
  if (warm == 0) {
    locker = await _lock(lock);
    sw.start();
    cpu0 = _cpuTicks();
  }
  while (frame < end) {
    if (frameRunner) {
      (core as dynamic).runFrame(core.scanlinesInFrame);
    } else {
      final r = core.exec(false);
      if (!r.scanlineRendered) continue;
      if (++lines < core.scanlinesInFrame) continue;
      lines = 0;
    }
    frame++;
    await drive?.settle();
    for (final (f, b) in pressList) {
      if (frame == f) core.padDown(0, buttons[b]);
      if (frame == f + hold) core.padUp(0, buttons[b]);
    }
    final ib = core.imageBuffer();
    final w = ib.buffer.buffer
        .asUint32List(ib.buffer.offsetInBytes, ib.buffer.length >> 2);
    int h = imageHash;
    for (int i = 0; i < w.length; i += 7) {
      h = ((h ^ w[i]) * 0x01000193) & 0xffffffff;
    }
    imageHash = h;
    if (outDir != null && frame % every == 0) {
      final image = img.Image.fromBytes(
          width: ib.width,
          height: ib.height,
          bytes: ib.buffer.buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba);
      File("$outDir/frame_${frame.toString().padLeft(5, "0")}.png")
          .writeAsBytesSync(img.encodePng(image));
    }
    if (frame == warm) {
      locker = await _lock(lock);
      sw.start();
      cpu0 = _cpuTicks();
    }
  }
  sw.stop();
  final cpuMs = (_cpuTicks() - cpu0) * 10;
  locker?.stdin.close();
  await locker?.exitCode;
  if (outDir != null) {
    File("$outDir/audio.pcm").writeAsBytesSync(pcm!.toBytes());
    File("$outDir/vram.bin")
        .writeAsBytesSync(core.gpu.frameBuffer.buffer.asUint8List());
  }
  stderr.writeln("timed $measure frames: ${sw.elapsedMilliseconds} ms "
      "(${(sw.elapsedMicroseconds / measure / 1000).toStringAsFixed(2)} ms/frame, "
      "${(measure * 1e6 / sw.elapsedMicroseconds).toStringAsFixed(1)} fps) "
      "cpu $cpuMs ms total ${total.elapsedMilliseconds} ms "
      "image:${imageHash.toRadixString(16)} audio:${audioHash.toRadixString(16)} "
      "pc:${core.cpu.pc.toRadixString(16)} clocks:${core.cpu.clocks}");
  exit(0);
}

String? _syncDir;

// user + system cpu time of this process in 10ms ticks (linux)
int _cpuTicks() {
  try {
    final f = File("/proc/self/stat").readAsStringSync();
    final v = f.substring(f.lastIndexOf(")") + 2).split(" ");
    return int.parse(v[11]) + int.parse(v[12]);
  } catch (_) {
    return 0;
  }
}

// holds a flock(1) lock until the returned process' stdin is closed
Future<Process?> _lock(String? path) async {
  if (_syncDir != null) {
    File("$_syncDir/ready.$pid").writeAsStringSync("");
    while (!File("$_syncDir/go").existsSync()) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
    return null;
  }
  if (path == null) return null;
  final p = await Process.start("flock", [path, "-c", "echo locked; exec cat"]);
  await p.stdout
      .transform(utf8.decoder)
      .firstWhere((s) => s.contains("locked"));
  return p;
}
