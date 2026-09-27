import 'dart:convert';
import 'dart:io';
import 'package:fnesemu/core/n64/n64.dart';
import 'package:fnesemu/core/pad_button.dart';
import 'package:fnesemu/core/sram.dart';

/// Private ROMs stay outside the repository. Writes raw RGBA evidence to /tmp.
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart tool/n64_smoke.dart ROM [cycles] [--input]');
    exit(64);
  }
  final core = N64()..setSram(Sram());
  var audioSamples = 0, audioNonzero = 0;
  var audioPeak = 0.0;
  core.onAudio((buffer) {
    audioSamples += buffer.buffer.length;
    for (final v in buffer.buffer) {
      if (v.abs() > 1 / 32768) audioNonzero++;
      if (v.abs() > audioPeak) audioPeak = v.abs();
    }
  });
  core.setRom(File(args[0]).readAsBytesSync());
  core.reset();
  final limits = args.skip(1).where((arg) => !arg.startsWith('--'));
  final limit =
      limits.isNotEmpty ? int.parse(limits.first) : core.systemClockHz * 12;
  final outputs = args.where((arg) => arg.startsWith('--out='));
  final directory = Directory(
      outputs.isEmpty ? Directory.systemTemp.path : outputs.first.substring(6));
  directory.createSync(recursive: true);
  final inputOptions = args.where((arg) => arg.startsWith('--input-events='));
  final input = args.contains('--input') || inputOptions.isNotEmpty;
  final timer = Stopwatch()..start();
  var nextReport = core.systemClockHz;
  var phase = 0;
  final defaultTimeline = <(double, String, bool)>[
    (6, 'start', true),
    (6.2, 'start', false),
    (8, 'start', true),
    (8.2, 'start', false),
    (11, 'A', true),
    (11.2, 'A', false),
    for (final second in [60, 62, 64, 66, 68, 72, 75, 78, 81]) ...[
      (second.toDouble(), 'A', true),
      (second + 0.2, 'A', false)
    ],
    (69, 'up', true),
    (85, 'up', false)
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final timeline = inputOptions.isEmpty
      ? defaultTimeline
      : (jsonDecode(File(inputOptions.first.substring(15)).readAsStringSync())
              as List)
          .map((e) => ((e[0] as num).toDouble(), e[1] as String, e[2] as bool))
          .toList();
  final watchOptions = args.where((arg) => arg.startsWith('--watch='));
  final watched = watchOptions.isEmpty
      ? <int>{}
      : watchOptions.first
          .substring(8)
          .split(',')
          .map((v) => int.parse(v, radix: 16))
          .toSet();
  while (core.cpu.clocks < limit) {
    if (watched.contains(core.cpu.pc)) {
      stdout.writeln(
          'watch ${(core.cpu.clocks / core.systemClockHz).toStringAsFixed(4)} '
          '${core.cpu.pc.toRadixString(16)} v0=${core.cpu.r[2]} '
          'a0=${core.cpu.r[4]} ra=${core.cpu.r[31]}');
    }
    if (input &&
        phase < timeline.length &&
        core.cpu.clocks >= timeline[phase].$1 * core.systemClockHz) {
      final event = timeline[phase++];
      if (event.$3) {
        core.padDown(0, PadButton(event.$2));
      } else {
        core.padUp(0, PadButton(event.$2));
      }
      stdout.writeln('input ${event.$1} ${event.$2} ${event.$3}');
    }
    if (core.cpu.clocks >= nextReport) {
      final image = core.imageBuffer(),
          second = nextReport ~/ core.systemClockHz;
      File('${directory.path}/fnesemu-n64-$second.rgba')
          .writeAsBytesSync(image.buffer);
      File('${directory.path}/fnesemu-n64-$second.json')
          .writeAsStringSync(jsonEncode({
        'width': image.width,
        'height': image.height,
        'pc': core.cpu.pc,
        'vi': core.bus.vi,
        'colorImage': core.graphics.colorImage,
        'segments': core.graphics.segments,
        'gfxTasks': core.graphics.tasks,
        'triangles': core.graphics.triangles,
        'audioTasks': core.audio.tasks,
        'samples': audioSamples,
        'nonzero': audioNonzero,
        'peak': audioPeak
      }));
      if (args.contains('--dump-ram')) {
        File('${directory.path}/fnesemu-n64-$second.ram.gz')
            .writeAsBytesSync(gzip.encode(core.bus.ram));
      }
      stdout.writeln(
          'second $second graphics ${core.graphics.tasks}/${core.graphics.triangles} audio ${core.audio.tasks} nonzero $audioNonzero pc ${core.cpu.pc.toRadixString(16)} extended ${core.graphics.extended}');
      nextReport += core.systemClockHz;
    }
    if (args.contains('--sample-frames')) {
      core.graphics.rasterize = core.cpu.clocks % core.systemClockHz >=
          core.systemClockHz -
              core.clocksInScanline * core.scanlinesInFrame * 6;
    }
    if (core.exec(false).stopped) break;
  }
  stdout.writeln(core.dump());
  stdout.writeln(
      'CP0 ${core.cpu.cop0.map((v) => v.toRadixString(16)).join(' ')}');
  stdout.writeln(
      'graphics ${core.graphics.tasks}/${core.graphics.triangles}; audio ${core.audio.tasks} samples $audioSamples nonzero $audioNonzero peak $audioPeak; ${timer.elapsedMilliseconds}ms');
  if (core.cpu.stopReason != null) exitCode = 1;
}
