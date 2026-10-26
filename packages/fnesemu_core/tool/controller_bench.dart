// Measures the controller loop including yields, without Flutter rendering.
// Usage: controller_bench <bios> <disc> [-w frames] [-m frames] [-p frame:button]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core_module.dart';
import 'package:fnesemu_core/src/internal/core_registry.dart';

import 'cdrom_drive.dart';
import 'local_disc.dart';
import 'logging.dart';

final class _BenchModule extends CoreModule {
  final Core core;
  final CoreSystem system;
  _BenchModule(this.core, this.system);
  @override
  List<CoreSystem> get systems => [system];
  @override
  Core create(String id) => core;
  @override
  CoreSystem? identifyRom(String name, Uint8List body) => null;
}

int _cpuTicks() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return int.parse(fields[11]) + int.parse(fields[12]);
}

Future<void> main(List<String> args) => runControllerBench(args);

Future<void> runControllerBench(List<String> args,
    {Future<void> Function(CoreController)? onReady,
    void Function(AudioBuffer)? onAudio,
    void Function(ImageBuffer)? onImage}) async {
  configureLogging();
  var warm = 2400, measure = 600;
  final presses = <(int, String)>[];
  final files = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-w':
        warm = int.parse(args[++i]);
      case '-m':
        measure = int.parse(args[++i]);
      case '-p':
        final parts = args[++i].split(':');
        presses.add((int.parse(parts[0]), parts[1]));
      default:
        files.add(args[i]);
    }
  }
  final system = files.isNotEmpty && const ['ps', 'n64'].contains(files.first)
      ? files.removeAt(0)
      : 'ps';
  if (files.length != (system == 'ps' ? 2 : 1) || measure <= 0 || warm < 0) {
    throw ArgumentError(
        'Expected [ps] BIOS disc or n64 ROM and a positive frame count');
  }
  final core = CoreFactory.of(system);
  registerCoreModules([_BenchModule(core, CoreFactory.system(system))]);
  SimpleCdromDrive? drive;
  Uint8List? rom;
  if (system == 'ps') {
    drive = SimpleCdromDrive();
    await drive.insert(localDisc(files[1]));
  } else {
    rom = File(files[0]).readAsBytesSync();
    if (files[0].toLowerCase().endsWith('.zip')) {
      final archive = ZipDecoder().decodeBytes(rom);
      final file = archive.files.firstWhere((f) =>
          f.isFile &&
          const ['.z64', '.v64', '.n64']
              .any((ext) => f.name.toLowerCase().endsWith(ext)));
      rom = Uint8List.fromList(file.content as List<int>);
    }
  }
  var measured = 0, imageHash = 0x811c9dc5, audioHash = 0x811c9dc5;
  var timing = false;
  final pad = PadState();
  core.input = pad;
  void applyInputs(int frame) {
    for (final (at, name) in presses) {
      final button = core.buttons
          .firstWhere((b) => b.name.toLowerCase() == name.toLowerCase());
      if (frame == at) pad.press(0, button);
      if (frame == at + 12) pad.release(0, button);
    }
  }

  late CoreController controller;
  controller = CoreController((_) {}, (AudioBuffer audio) {
    if (!timing) return;
    onAudio?.call(audio);
    for (final sample in audio.buffer) {
      final value = (sample.clamp(-1.0, 1.0) * 32767).round() & 0xffff;
      audioHash = ((audioHash ^ value) * 0x01000193) & 0xffffffff;
    }
  }, (ImageBuffer image) {
    if (!timing) return;
    onImage?.call(image);
    for (var i = 0; i < image.buffer.length; i += 7) {
      imageHash = ((imageHash ^ image.buffer[i]) * 0x01000193) & 0xffffffff;
    }
    measured++;
    applyInputs(warm + 1 + measured);
    if (measured >= measure) unawaited(controller.stop());
  }, Sram());
  await controller.init(system,
      rom: rom,
      bios: system == 'ps' ? [File(files[0]).readAsBytesSync()] : [],
      drive: drive);

  // Fast-forward identically, settling disc reads after each frame.
  for (var frame = 1; frame <= warm; frame++) {
    core.runFrame(core.scanlinesInFrame);
    await drive?.settle();
    applyInputs(frame);
  }
  // Synchronize controller clocks after direct warm-up.
  await controller.debugger.runToFrame();
  await drive?.settle();
  applyInputs(warm + 1);
  controller.debugger.setDebugView(false);
  await onReady?.call(controller);
  final intervals = <int>[];
  final watch = Stopwatch();
  var previousProbe = 0;
  final probe = Timer.periodic(const Duration(milliseconds: 16), (_) {
    final now = watch.elapsedMicroseconds;
    intervals.add(now - previousProbe);
    previousProbe = now;
  });
  final clocks = core.cpuClocks;
  final cpu = _cpuTicks();
  timing = true;
  watch.start();
  await controller.run();
  watch.stop();
  timing = false;
  probe.cancel();
  final cpuMs = (_cpuTicks() - cpu) * 10;
  intervals.sort();
  final elapsedMs = watch.elapsedMicroseconds / 1000;
  print(jsonEncode({
    'core': system,
    'jitEnabled': core.jitEnabled,
    'jitClocks': core.jitClocks,
    'frames': measured,
    'wall_ms': elapsedMs,
    'fps': measured * 1000 / elapsedMs,
    'cpu_ms': cpuMs,
    'cpu_percent': cpuMs * 100 / elapsedMs,
    'probe_p95_ms': intervals.isEmpty
        ? null
        : intervals[((intervals.length - 1) * .95).round()] / 1000,
    'probe_max_ms': intervals.isEmpty ? null : intervals.last / 1000,
    'image': imageHash.toRadixString(16),
    'audio': audioHash.toRadixString(16),
    'pc': core.programCounter(core.cpuInfos.first.no).toRadixString(16),
    'clocks': core.cpuClocks - clocks,
  }));
  core.dispose();
  exit(0);
}
