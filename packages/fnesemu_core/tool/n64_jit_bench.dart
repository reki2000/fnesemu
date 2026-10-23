// AOT comparison of fixed integer loops. This does not predict game FPS.
import 'dart:convert';

import 'package:fnesemu_core/src/core/n64/bus.dart';
import 'package:fnesemu_core/src/core/n64/cpu.dart';
import 'package:fnesemu_core/src/core/n64/jit/n64_jit.dart';

void main(List<String> args) {
  final nativeOnly = args.contains('--native-only');
  final rounds = nativeOnly ? 9 : 3;
  final limit = nativeOnly ? 40200000 : 4200000;
  for (var round = 0; round < rounds; round++) {
    for (final wide in [false, true]) {
      for (final compiled in round.isEven ? [false, true] : [true, false]) {
        if (nativeOnly && !compiled) continue;
        final jit = compiled
            ? N64Jit.create(compileThreshold: 1, inlineJumps: false)
            : null;
        if (compiled && jit == null) continue;
        final bus = N64Bus(ram: jit?.ram);
        final cpu = Vr4300(bus, registers: jit?.regs, fpu: jit?.fpu);
        jit?.attach(cpu, bus);
        final ops = wide
            ? [
                0x01ae682d,
                0x000d783c,
                0x000f783e,
                0x01af6826,
                0xfc8d0000,
                0xdc8d0000,
                0x1000fff9,
                0
              ]
            : [
                0x8c880000,
                0x25080001,
                0xac880000,
                0x010a4826,
                0x000948c0,
                0x00491021,
                0x1000fff9,
                0
              ];
        for (var i = 0; i < ops.length; i++)
          bus.ramWrite(0x1000 + i * 4, ops[i], 4);
        cpu.reset(0x80001000);
        cpu.r[4] = 0x80002000.toSigned(32);
        cpu.r[10] = 0x12345678;
        cpu.r[13] = 0x123456789abcdef0;
        cpu.r[14] = 0xfedcba9876543210;
        void run(int limit) {
          while (cpu.clocks < limit) {
            if (jit?.run((limit - cpu.clocks).clamp(0, 256)) != true)
              cpu.step();
            if (cpu.stopReason != null) throw StateError(cpu.stopReason!);
          }
        }

        run(200000);
        final watch = Stopwatch()..start();
        run(limit);
        watch.stop();
        print(jsonEncode({
          'round': round,
          'wide': wide,
          'jit': compiled,
          'us': watch.elapsedMicroseconds,
          'clocks': cpu.clocks,
          'checksum': cpu.r[wide ? 13 : 2],
          'ram': bus.ramRead(0x2000, 4),
          'compiledClocks': jit?.compiledClocks ?? 0,
        }));
        jit?.dispose();
      }
    }
  }
}
