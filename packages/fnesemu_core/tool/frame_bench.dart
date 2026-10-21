// Time emulation after warmup, automatically taking the shared benchmark lock.
// Example: ./bench --case args.json --warmup 600 --frames 300
// The JSON file contains core_harness arguments, including the input schedule.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu_core/src/core.dart';
import 'package:fnesemu_core/src/core/gb/gb.dart';
import 'package:fnesemu_core/src/core/gba/gba.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/nes/nes.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:fnesemu_core/src/sram.dart';

import 'input_sequence.dart';
import 'logging.dart';

Future<void> main(List<String> options) async {
  configureLogging();
  String? caseFile, out;
  var warmup = 600, measured = 300, repetitions = 1, frameRunner = false;
  for (var i = 0; i < options.length; i++) {
    switch (options[i]) {
      case '--case':
        caseFile = options[++i];
      case '--warmup':
        warmup = int.parse(options[++i]);
      case '--frames':
        measured = int.parse(options[++i]);
      case '--repetitions':
        repetitions = int.parse(options[++i]);
      case '--frame-runner':
        frameRunner = true;
      case '--out':
        out = options[++i];
      default:
        throw ArgumentError('Unknown option ${options[i]}');
    }
  }
  if (caseFile == null || warmup < 0 || measured <= 0 || repetitions <= 0) {
    throw ArgumentError('--case FILE [--warmup N] [--frames N] '
        '[--repetitions N] [--frame-runner] [--out DIR]');
  }
  final args =
      (jsonDecode(File(caseFile).readAsStringSync()) as List).cast<String>();
  final core = createCore(args[0]);
  core.setSram(Sram());
  var input = '';
  for (var i = 2; i < args.length; i++) {
    switch (args[i]) {
      case '-b':
        core.setBiosFiles([File(args[++i]).readAsBytesSync()]);
      case '-i' || '--input':
        input = args[++i];
      case '-f' || '-e' || '-s' || '-o':
        i++;
      case '-w':
        break;
      default:
        throw ArgumentError('Unsupported case argument ${args[i]}');
    }
  }
  var bytes = File(args[1]).readAsBytesSync();
  if (args[1].toLowerCase().endsWith('.zip')) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final file = archive.files.firstWhere((f) =>
        f.isFile &&
        ['.nes', '.gb', '.gbc', '.gba', '.smc', '.sfc', '.z64', '.v64', '.n64']
            .any((ext) => f.name.toLowerCase().endsWith(ext)));
    bytes = Uint8List.fromList(file.content as List<int>);
  }
  core.setRom(bytes);
  if (args[0] != 'gba') core.reset();
  final buttons = core.buttons;
  final pad = PadPlayer(
      resolveInput(input, buttons.map((b) => b.name).toList()),
      buttons.length);
  final audio = BytesBuilder();
  var samples = 0;
  core.onAudio((buffer) {
    samples += buffer.buffer.length;
    if (out != null) {
      audio.add(buffer.buffer.buffer.asUint8List(
          buffer.buffer.offsetInBytes, buffer.buffer.lengthInBytes));
    }
  });
  if (out != null) Directory(out).createSync(recursive: true);
  final ticksPerSecond = int.parse(
      (Process.runSync('getconf', ['CLK_TCK']).stdout as String).trim());
  int cpuTicks() {
    final stat = File('/proc/self/stat').readAsStringSync();
    final fields = stat.substring(stat.lastIndexOf(')') + 2).trim().split(' ');
    return int.parse(fields[11]) + int.parse(fields[12]);
  }

  var startTicks = 0;
  final timer = Stopwatch();
  var clocks = 0;
  Process? lock;
  try {
    for (var frame = 1; frame <= warmup + measured * repetitions; frame++) {
      if (frame > warmup && (frame - warmup - 1) % measured == 0) {
        lock = await Process.start('flock', [
          '/tmp/claude-1000/fnesemu-bench.lock',
          'sh',
          '-c',
          'echo locked; read release',
        ]);
        final ready = await lock.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        if (ready != 'locked') throw StateError('Benchmark lock not acquired');
        timer.reset();
        startTicks = cpuTicks();
      }
      if (frame > warmup) timer.start();
      if (frameRunner) {
        final result = core.runFrame(core.scanlinesInFrame);
        if (result.stopped) throw StateError('Stopped at frame $frame');
        clocks = result.elapsedClocks;
      } else {
        var lines = 0;
        while (lines < core.scanlinesInFrame) {
          final result = core.exec(false);
          if (result.stopped) throw StateError('Stopped at frame $frame');
          if (result.scanlineRendered) lines++;
          clocks = result.elapsedClocks;
        }
      }
      timer.stop();
      if (frame <= warmup && frame % 600 == 0) {
        stderr.writeln('warmup $frame/$warmup');
      }
      pad.step(frame, (b, down) {
        down ? core.padDown(0, buttons[b]) : core.padUp(0, buttons[b]);
      });
      if (out != null &&
          (frame % 150 == 0 || frame == warmup + measured * repetitions)) {
        final image = core.imageBuffer();
        File('$out/frame_$frame.rgba').writeAsBytesSync(image.bytes);
      }
      if (frame > warmup && (frame - warmup) % measured == 0) {
        final cpuUs = (cpuTicks() - startTicks) * 1000000 ~/ ticksPerSecond;
        lock!.stdin.writeln('release');
        await lock.stdin.close();
        if (await lock.exitCode != 0) throw StateError('Benchmark lock failed');
        lock = null;
        stdout.writeln(jsonEncode({
          'core': args[0],
          'frameRunner': frameRunner,
          'rep': (frame - warmup) ~/ measured - 1,
          'fromFrame': frame - measured + 1,
          'toFrame': frame,
          'warmup': warmup,
          'frames': measured,
          'us': timer.elapsedMicroseconds,
          'msPerFrame': timer.elapsedMicroseconds / measured / 1000,
          'fps': timer.elapsedMicroseconds > 0
              ? measured * 1000000 / timer.elapsedMicroseconds
              : null,
          'cpuUs': cpuUs,
          'cpuMsPerFrame': cpuUs / measured / 1000,
          'cpuFps': cpuUs > 0 ? measured * 1000000 / cpuUs : null,
          'clocks': clocks,
          'samples': samples
        }));
      }
    }
  } finally {
    // Closing stdin also releases flock if emulation or output throws.
    if (lock != null) {
      await lock.stdin.close();
      await lock.exitCode;
    }
  }
  if (out != null) {
    File('$out/audio.f32').writeAsBytesSync(audio.takeBytes());
    File('$out/state.txt')
        .writeAsStringSync('$clocks $samples\n${core.dump()}');
  }
}

Core createCore(String name) {
  switch (name) {
    case 'gb':
      return Gb();
    case 'gba':
      return Gba();
    case 'snes':
      return Snes();
    case 'n64':
      return N64();
    case 'nes':
      return Nes();
    default:
      throw ArgumentError('Unsupported core $name');
  }
}
