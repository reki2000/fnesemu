// headless SS harness: runs BIOS (+ disc) and dumps frames as png
//
// usage: dart run tool/ss_harness.dart <bios> [disc] [options]
//   -f, --frames N   number of frames to run (default: 600)
//   -e, --every N    save a png every N frames (default: 60)
//   -o, --out DIR    output directory (default: /tmp/ss_harness)
//   -l, --log-cd     log CD block commands
//   -p, --press F:B  press button B (index) at frame F (repeatable)
//   -H, --hold N     frames to hold a pressed button (default: 10)
//   -w, --wav        also write audio.wav (16bit pcm) and audio.f32 (raw float)
//   -q, --quiet      no per-png log, print only the total time (benchmark)
//   --fixed-clock    the real time clock always reads 2000-01-01 and the disc
//                    cache does not expire by wall time (reproducible runs)
//   -r, --run-frame  drive the core by runFrame() (as the gui does) instead of exec()
//   -b, --bench-from N  time only the frames after frame N
//   --lock FILE      hold flock(1) on FILE while timing (shared benchmark lock)
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/core.dart';
import 'package:fnesemu_core/src/core/sram.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:fnesemu_core/src/core/types.dart';
import 'package:image/image.dart' as img;

import 'cdrom_drive.dart';
import 'local_disc.dart';

Future<void> main(List<String> args) async {
  int frames = 600;
  int every = 60;
  String outDir = "/tmp/ss_harness";
  final presses = <(int, int)>[];
  bool logCd = false;
  bool wav = false;
  bool quiet = false;
  bool useRunFrame = false;
  bool fixedClock = false;
  int benchFrom = 0;
  String? lockFile;
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
      case "-w" || "--wav":
        wav = true;
      case "-b" || "--bench-from":
        benchFrom = int.parse(args[++i]);
      case "--lock":
        lockFile = args[++i];
      case "--fixed-clock":
        fixedClock = true;
      case "-r" || "--run-frame":
        useRunFrame = true;
      case "-q" || "--quiet":
        quiet = true;
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
  SimpleCdromDrive? drive;
  if (files.length > 1) {
    drive = SimpleCdromDrive();
    await drive.insert(localDisc(files[1]));
    if (!drive.status.isReady) throw "cannot read disc: ${files[1]}";
    ss.setCdromDrive(drive);
  }
  ss.reset();
  ss.cdblock.log = logCd;
  if (fixedClock) ss.smpc.clock = () => DateTime(2000, 1, 1);

  final f32 = BytesBuilder(copy: false);
  if (wav) {
    ss.onAudio((buf) {
      f32.add(Float32List.fromList(buf.buffer).buffer.asUint8List());
    });
  }

  final sw = Stopwatch()..start();
  int lines = 0;
  int frame = 0;
  Process? lock;
  int cpuStart = 0;

  Future<void> startBench() async {
    if (lockFile != null) {
      lock = await Process.start(
          "flock", [lockFile, "sh", "-c", "echo locked; read x"]);
      await lock!.stdout.transform(utf8.decoder).first;
    }
    sw.reset();
    cpuStart = _cpuMs();
  }

  if (benchFrom == 0) await startBench();

  while (frame < frames) {
    final r = useRunFrame
        ? (ss as FrameRunner).runFrame(ss.scanlinesInFrame)
        : ss.exec(false);
    if (r.stopped) {
      print("stopped at frame $frame\n${ss.dump()}");
      _savePng(ss.imageBuffer(), "$outDir/stopped.png");
      exit(2);
    }
    if (!useRunFrame) {
      if (!r.scanlineRendered) continue;
      if (++lines < ss.scanlinesInFrame) continue;
    }
    lines = 0;
    frame++;
    await drive?.settle(); // result must not depend on the speed of the disc
    if (frame == benchFrom) await startBench();

    for (final (f, b) in presses) {
      if (frame == f) ss.padDown(0, ss.buttons[b]);
      if (frame == f + holdFrames) ss.padUp(0, ss.buttons[b]);
    }

    if (frame % every == 0) {
      final path = "$outDir/frame_${frame.toString().padLeft(5, "0")}.png";
      _savePng(ss.imageBuffer(), path);
      if (quiet) continue;
      print("frame $frame (${(sw.elapsedMilliseconds / frame).toStringAsFixed(1)} ms/frame) "
          "pc:${ss.master.pc.toRadixString(16)} "
          "slave:${ss.slave.pc.toRadixString(16)} "
          "68k:${ss.scsp.cpu.pc.toRadixString(16)} -> $path");
      print("  ${ss.cdblock.dump()}");
    }
  }

  final ms = sw.elapsedMilliseconds;
  final cpuMs = _cpuMs() - cpuStart;
  if (lock != null) {
    lock!.stdin.writeln();
    await lock!.stdin.close();
    await lock!.exitCode;
  }
  final n = frames - benchFrom;
  print("total $n frames ($benchFrom-$frames) in $ms ms: "
      "${(ms / n).toStringAsFixed(3)} ms/frame, "
      "${(n * 1000 / ms).toStringAsFixed(1)} fps, "
      "cpu ${(cpuMs / n).toStringAsFixed(3)} ms/frame");

  if (wav) {
    final raw = f32.toBytes();
    File("$outDir/audio.f32").writeAsBytesSync(raw);
    File("$outDir/audio.wav").writeAsBytesSync(_wav(raw.buffer.asFloat32List(
        raw.offsetInBytes, raw.length ~/ 4)));
  }
  File("$outDir/state.txt").writeAsStringSync(ss.dump());
  if (!quiet) print(ss.dump());
}

// cpu time (user + system) of this process in ms, 0 when not available
int _cpuMs() {
  try {
    final stat = File("/proc/self/stat").readAsStringSync();
    final f = stat.substring(stat.lastIndexOf(")") + 2).split(" ");
    return (int.parse(f[11]) + int.parse(f[12])) * 10; // 100 ticks / s
  } catch (_) {
    return 0;
  }
}

// 16bit stereo pcm
Uint8List _wav(Float32List samples) {
  const rate = 44100, channels = 2;
  final pcm = ByteData(samples.length * 2);
  for (int i = 0; i < samples.length; i++) {
    pcm.setInt16(i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(),
        Endian.little);
  }
  final h = ByteData(44);
  void tag(int o, String s) {
    for (int i = 0; i < 4; i++) {
      h.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  tag(0, "RIFF");
  h.setUint32(4, 36 + pcm.lengthInBytes, Endian.little);
  tag(8, "WAVE");
  tag(12, "fmt ");
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, channels, Endian.little);
  h.setUint32(24, rate, Endian.little);
  h.setUint32(28, rate * channels * 2, Endian.little);
  h.setUint16(32, channels * 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, "data");
  h.setUint32(40, pcm.lengthInBytes, Endian.little);
  return Uint8List.fromList(
      [...h.buffer.asUint8List(), ...pcm.buffer.asUint8List()]);
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
