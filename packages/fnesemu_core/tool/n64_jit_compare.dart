// Alternates short batches in one AOT process to reduce host-load drift.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/sram.dart';

import 'logging.dart';

final class _Variant {
  final int size;
  final String name;
  final N64 core;
  final watch = Stopwatch();
  int cpuTicks = 0, audioHash = 0x811c9dc5, samples = 0;
  final batches = <Map<String, int>>[];
  _Variant(this.name, this.size,
      {bool fpu = true,
      bool inline = false,
      bool cop1 = false,
      bool nativeFpu = false})
      : core = N64(
            jit: size != 0,
            jitStatistics: false,
            jitCop1: cop1,
            jitNativeFpu: nativeFpu,
            jitFpu: fpu,
            inlineJumps: inline,
            maxBlockInstructions: size == 0 ? null : size) {
    core.setSram(Sram());
    core.onAudio((audio) {
      samples += audio.buffer.length;
      final words = Uint32List.view(
          audio.buffer.buffer, audio.buffer.offsetInBytes, audio.buffer.length);
      for (final word in words) {
        audioHash = ((audioHash ^ word) * 0x01000193) & 0xffffffff;
      }
    });
  }
}

int _ticks() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return int.parse(fields[11]) + int.parse(fields[12]);
}

void _same(N64 a, N64 b) {
  if (a.dump() != b.dump() || a.cpu.nextPc != b.cpu.nextPc) {
    throw StateError('CPU state differs');
  }
  for (var i = 0; i < a.bus.ram.length; i++) {
    if (a.bus.ram[i] != b.bus.ram[i]) throw StateError('RAM differs at $i');
  }
  final af = a.cpu.fpu.data, bf = b.cpu.fpu.data;
  if (a.cpu.fpu.wide != b.cpu.fpu.wide) throw StateError('FPU layout differs');
  for (var i = 0; i < af.lengthInBytes; i++) {
    if (af.getUint8(i) != bf.getUint8(i))
      throw StateError('FPU register differs at $i');
  }
  final x = a.imageBuffer().buffer, y = b.imageBuffer().buffer;
  if (x.length != y.length) throw StateError('Image dimensions differ');
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) throw StateError('Image differs at $i');
  }
}

Future<void> main(List<String> args) async {
  configureLogging();
  String? caseFile;
  var warm = 900, frames = 300, batch = 10;
  var includeInline = false, includeFpu = false, includeCop1 = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--case':
        caseFile = args[++i];
      case '--warmup':
        warm = int.parse(args[++i]);
      case '--frames':
        frames = int.parse(args[++i]);
      case '--batch':
        batch = int.parse(args[++i]);
      case '--inline':
        includeInline = true;
      case '--cop1':
        includeCop1 = true;
      case '--fpu':
        includeFpu = true;
      default:
        throw ArgumentError('Unknown option ${args[i]}');
    }
  }
  if (caseFile == null || frames <= 0 || batch <= 0 || frames % batch != 0) {
    throw ArgumentError('--case FILE --warmup N --frames N --batch N');
  }
  final config =
      (jsonDecode(File(caseFile).readAsStringSync()) as List).cast<String>();
  var rom = File(config[1]).readAsBytesSync();
  if (config[1].toLowerCase().endsWith('.zip')) {
    final archive = ZipDecoder().decodeBytes(rom);
    rom = Uint8List.fromList(archive.files
        .firstWhere((f) =>
            f.isFile &&
            const ['.z64', '.v64', '.n64']
                .any((ext) => f.name.toLowerCase().endsWith(ext)))
        .content as List<int>);
  }
  var hold = 12;
  final inputs = <(int, String)>[];
  for (var i = 2; i < config.length; i++) {
    if (config[i] == '-H') hold = int.parse(config[++i]);
    if (config[i] == '-p') {
      final parts = config[++i].split(':');
      inputs.add((int.parse(parts[0]), parts[1]));
    }
  }
  final variants = [
    _Variant('interpreter', 0),
    _Variant('i64', 24, fpu: false),
    if (includeCop1) _Variant('transfers', 24, fpu: false, cop1: true),
    if (includeCop1)
      _Variant('native-fp', 24, fpu: false, cop1: true, nativeFpu: true),
    if (includeFpu) _Variant('fpu24', 24),
    if (includeInline) _Variant('inline24', 24, inline: true, fpu: false),
  ];
  void frame(_Variant v, int index) {
    final result = v.core.runFrame(v.core.scanlinesInFrame);
    if (result.stopped) throw StateError('CPU stopped at frame $index');
    for (final (at, name) in inputs) {
      final button = v.core.buttons
          .firstWhere((b) => b.name.toLowerCase() == name.toLowerCase());
      if (index == at) v.core.padDown(0, button);
      if (index == at + hold) v.core.padUp(0, button);
    }
  }

  void check() {
    for (final v in variants.skip(1)) {
      _same(variants.first.core, v.core);
      if (v.audioHash != variants.first.audioHash ||
          v.samples != variants.first.samples) {
        throw StateError('Audio history differs');
      }
    }
  }

  Process? lock;
  try {
    for (final v in variants) {
      v.core.setRom(Uint8List.fromList(rom));
      v.core.reset();
      if (v.size != 0 && !v.core.jitEnabled)
        throw StateError('Compiled backend unavailable');
    }
    for (var f = 1; f <= warm; f++) {
      for (final v in variants) frame(v, f);
      if (f % 300 == 0) stderr.writeln('warmup $f/$warm');
    }
    check();
    final hz = int.parse(
        (Process.runSync('getconf', ['CLK_TCK']).stdout as String).trim());
    lock = await Process.start('flock', [
      '/tmp/claude-1000/fnesemu-bench.lock',
      'sh',
      '-c',
      'echo locked; read release'
    ]);
    await lock.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    for (var part = 0; part < frames ~/ batch; part++) {
      // Rotate and reverse order, so no variant always follows the same one.
      final order = part.isEven ? variants : variants.reversed.toList();
      for (var n = 0; n < variants.length; n++) {
        final v = order[(n + part ~/ 2) % variants.length];
        final start = v.watch.elapsedMicroseconds, cpu = _ticks();
        v.watch.start();
        for (var f = 1; f <= batch; f++) frame(v, warm + part * batch + f);
        v.watch.stop();
        final spent = _ticks() - cpu;
        v.cpuTicks += spent;
        v.batches.add({
          'from': warm + part * batch + 1,
          'us': v.watch.elapsedMicroseconds - start,
          'cpuTicks': spent
        });
      }
      if ((part + 1) * batch % 100 == 0) {
        check();
        stderr.writeln('measured ${(part + 1) * batch}/$frames; states match');
      }
    }
    check();
    print(jsonEncode([
      for (final v in variants)
        {
          'name': v.name,
          'blockLimit': v.size,
          'frames': frames,
          'us': v.watch.elapsedMicroseconds,
          'msPerFrame': v.watch.elapsedMicroseconds / frames / 1000,
          'cpuMsPerFrame': v.cpuTicks * 1000 / hz / frames,
          'jitClocks': v.core.jitClocks,
          'clocks': v.core.cpu.clocks,
          'blockEnds': v.core.jit?.blockEnds,
          'samples': v.samples,
          'audioHash': v.audioHash,
          'blockSizes': {
            for (final e in (v.core.jit?.blockSizes ?? <int, int>{}).entries)
              e.key.toString(): e.value
          },
          'batches': v.batches,
        }
    ]));
  } finally {
    await lock?.stdin.close();
    await lock?.exitCode;
    for (final v in variants) v.core.dispose();
  }
}
