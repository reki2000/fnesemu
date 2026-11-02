// Synthetic PS2 EE JIT benchmark with repeated device reads; no ROM or BIOS.
//
// dart build cli -t tool/ps2_jit_mmio_bench.dart -o /tmp/ps2-jit-mmio
// /tmp/ps2-jit-mmio/bundle/bin/ps2_jit_mmio_bench [mmio|ram] [rounds]
//
// Compare AOT builds, not dart run. The checksum, read count and guest clocks
// must match; native entries show how often execution crossed into the JIT.
import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/jit/ps2_jit.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';

int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);

const _code = 0x100000, _outer = 3000, _inner = 1000;

class _BenchIo implements IoPort {
  int reads = 0;

  @override
  bool handles(int address) => address == 0x1000f000;

  @override
  int read(int address, int size) {
    reads++;
    return 0x12345678;
  }

  @override
  bool write(int address, int size, int value) => false;
}

void main(List<String> args) {
  if (args.length > 2) throw ArgumentError('expected [mmio|ram] [rounds]');
  final mode = args.isEmpty ? 'mmio' : args[0];
  if (mode != 'mmio' && mode != 'ram') throw ArgumentError('unknown mode');
  final rounds = args.length < 2 ? 5 : int.parse(args[1]);
  if (rounds < 1) throw ArgumentError('rounds must be positive');
  int? expectedClocks, expectedChecksum;
  var best = double.infinity;
  for (var round = 0; round < rounds; round++) {
    final sw = Stopwatch()..start();
    final jit = Ps2Jit.create()!;
    final io = _BenchIo();
    final bus = Ps2Bus(ram: jit.ram)..io = io;
    final cpu = R5900(bus, gpr: jit.gpr);
    jit.attach(cpu);
    final address = mode == 'mmio' ? 0x1000f000 : 0x00200000;
    if (mode == 'ram') bus.write32(address, 0x12345678);
    final program = [
      _i(15, 0, 8, address >> 16), // lui t0, upper address
      _i(13, 8, 8, address), // ori t0, t0, lower address
      _i(9, 0, 16, _outer), // addiu s0, r0, outer
      _i(9, 0, 10, _inner), // outer: addiu t2, r0, inner
      _i(35, 8, 11, 0), // inner: lw t3, 0(t0)
      _i(9, 10, 10, -1), // addiu t2, t2, -1
      _i(5, 10, 0, -3), // bne t2, r0, inner
      0, // nop (delay slot)
      _i(9, 16, 16, -1), // addiu s0, s0, -1
      _i(5, 16, 0, -7), // bne s0, r0, outer
      0, // nop (delay slot)
    ];
    for (final (i, inst) in program.indexed) {
      bus.write32(_code + 4 * i, inst);
    }
    cpu.jumpTo(_code);
    final end = _code + program.length * 4;
    while (cpu.pc != end) {
      if (!jit.run(32) && !cpu.step()) {
        throw StateError('unimplemented at 0x${cpu.pc.toRadixString(16)}');
      }
    }
    final reads = io.reads, value = cpu.reg(11), clocks = cpu.clocks;
    final entries = jit.rt.nativeEntries;
    jit.dispose();
    sw.stop();
    if (reads != (mode == 'mmio' ? _outer * _inner : 0) ||
        value != 0x12345678) {
      throw StateError('unexpected IO reads or load result');
    }
    final checksum = reads * 31 ^ value;
    expectedClocks ??= clocks;
    expectedChecksum ??= checksum;
    if (clocks != expectedClocks || checksum != expectedChecksum) {
      throw StateError('guest clocks or checksum changed between rounds');
    }
    final ms = sw.elapsedMicroseconds / 1000;
    if (ms < best) best = ms;
    print('round $round: ${ms.toStringAsFixed(1)} ms, '
        '$clocks guest clocks, $entries native entries, checksum $checksum');
  }
  print('$mode: best ${best.toStringAsFixed(1)} ms');
}
