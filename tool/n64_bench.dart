import 'dart:io';
import 'package:fnesemu/core/n64/bus.dart';
import 'package:fnesemu/core/n64/cpu.dart';
import 'package:fnesemu/core/n64/graphics.dart';

void main() {
  for (final wide in [false, true]) {
    final cpu = Vr4300(N64Bus());
    // Share the CPU's bus; its RAM stores both code and loop data.
    final memory = cpu.bus;
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
    for (var i = 0; i < ops.length; i++) {
      memory.ramWrite(0x1000 + i * 4, ops[i], 4);
    }
    cpu.reset(0x80001000);
    cpu.r[4] = BigInt.from(0x80002000).toSigned(32);
    cpu.r[10] = BigInt.from(0x12345678);
    cpu.r[13] = BigInt.parse('123456789abcdef0', radix: 16);
    cpu.r[14] = BigInt.parse('fedcba9876543210', radix: 16).toSigned(64);
    for (var i = 0; i < 200000; i++) {
      cpu.step();
    }
    final timer = Stopwatch()..start();
    for (var i = 0; i < 4000000; i++) {
      cpu.step();
    }
    timer.stop();
    if (cpu.stopReason != null) throw StateError(cpu.stopReason!);
    stdout.writeln(
        'cpu ${wide ? 'mixed64' : 'word32'} ${timer.elapsedMicroseconds}us '
        'checksum=${cpu.r[wide ? 13 : 2]} ram=${memory.ramRead(0x2000, 4)}');
  }
  final g = N64Graphics(N64Bus());
  g.colorImage = 0x100000;
  g.combine1 = (7 << 28) | (4 << 15) | (7 << 12) | (6 << 9);
  final a = N64Vertex([-0.9, -0.8, 0, 1], [240, 10, 30, 255], 0, 0);
  final b = N64Vertex([0.8, -0.7, 0, 1], [20, 240, 10, 255], 0, 0);
  final c = N64Vertex([-0.2, 0.9, 0, 1], [10, 20, 240, 255], 0, 0);
  for (var i = 0; i < 10; i++) {
    g.triangle(a, b, c);
  }
  final timer = Stopwatch()..start();
  for (var i = 0; i < 300; i++) {
    g.triangle(a, b, c);
  }
  timer.stop();
  var hash = 0;
  for (final byte in g.bus.ram.sublist(0x100000, 0x100000 + 320 * 240 * 2)) {
    hash = (hash * 31 + byte) & 0xffffffff;
  }
  stdout.writeln('graphics ${timer.elapsedMicroseconds}us checksum=$hash');
}
