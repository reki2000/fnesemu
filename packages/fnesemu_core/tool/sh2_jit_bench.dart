import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ss/sh2/sh2.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:fnesemu_core/src/sram.dart';

import 'headless/jit_metrics.dart';

Future<void> main(List<String> args) async {
  final slices = args.contains('--slices');
  final lock = await Process.start('flock', [
    '/tmp/claude-1000/fnesemu-bench.lock',
    'sh',
    '-c',
    'echo locked; read release'
  ]);
  await lock.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  try {
    final bios = Uint8List(0x80000);
    final data = ByteData.sublistView(bios);
    data.setUint32(0, 0x100);
    data.setUint32(4, 0x060ff000);
    const ops = [0x7101, 0x321c, 0x231a, 0x2c12, 0x65c2, 0xaff9, 9];
    for (var i = 0; i < ops.length; i++) {
      data.setUint16(0x100 + i * 2, ops[i]);
    }
    final variants = [
      for (final quantum in slices ? [32, 64, 128] : [32])
        for (final jit in slices ? [true] : [false, true])
          Ss(jit: jit, sliceClocks: quantum)
            ..setSram(Sram())
            ..setRom(bios)
            ..reset()
    ];
    for (final core in variants) {
      (core.master as Sh2).r[12] = 0x06001000;
      for (var i = 0; i < 10; i++) {
        core.runFrame(core.scanlinesInFrame);
      }
    }
    for (var round = 0; round < 5; round++) {
      for (final k in round.isEven
          ? List.generate(variants.length, (i) => i)
          : List.generate(variants.length, (i) => variants.length - i - 1)) {
        final core = variants[k];
        final countersStart = JitCounters(core);
        final watch = Stopwatch()..start();
        for (var i = 0; i < 30; i++) {
          final result = core.runFrame(core.scanlinesInFrame);
          if (result.stopped) throw StateError('Stopped');
        }
        watch.stop();
        print(jsonEncode({
          'round': round,
          'jit': core.jitEnabled,
          'sliceClocks': slices ? [32, 64, 128][k] : 32,
          'us': watch.elapsedMicroseconds,
          'clocks': core.master.clocks,
          'r': (core.master as Sh2).r.toList(),
          'compiled': core.jitClocks,
          ...JitCounters(core).since(countersStart)
        }));
      }
      for (final b in variants.skip(1)) {
        final a = variants[0];
        if (a.master.dump() != b.master.dump() ||
            a.master.clocks != b.master.clocks) {
          throw StateError('State mismatch');
        }
        for (var i = 0; i < a.bus.wramH.length; i++) {
          if (a.bus.wramH[i] != b.bus.wramH[i]) {
            throw StateError('RAM mismatch');
        }
          }
      }
    }
    for (final v in variants) {
      v.dispose();
    }
  } finally {
    await lock.stdin.close();
    await lock.exitCode;
  }
}
