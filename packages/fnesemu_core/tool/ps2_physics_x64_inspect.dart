// Inspect x64 emitted by the production R5900 translator + IR optimizer +
// X64Backend for the actual EE physics ELF, not illustrative hand-written asm.
// A deterministic NativeEnv supplies code and guard addresses ONLY for dumping;
// instruction semantics, block selection and the x64 compiler are unchanged.
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:fnesemu_core/src/core/ps2/jit/r5900_translator.dart';
import 'package:mp_jit_recompiler/src/ir.dart';
import 'package:mp_jit_recompiler/src/optimizer.dart';
import 'package:mp_jit_recompiler/src/native_env.dart';
import 'package:mp_jit_recompiler/src/x64/backend.dart';

const _base = 0x100000;
const _end = 0x110000;
const _result = 0x200000;

final class _DumpEnv implements NativeEnv {
  int slot = 0;
  @override bool get win64 => false;
  @override int get blockEntryFn => 0;
  @override int get addrMask => 0x1fffffff;
  @override int get pageShift => 12;
  @override int get exitStub => 0x100000000;
  @override int get readFn => 0x100000100;
  @override int get writeFn => 0x100000200;
  @override int helperFn(int id) => 0x100000300 + id * 32;
  @override int? guardAddr(int guestAddr) => 0x200000000 + guestAddr;
  @override int slotFor(int pc, int tag) => slot++;
}

void loadElf(String name, Ps2Bus bus, R5900 cpu) {
  final bytes = File(name).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0, Endian.little) != 0x464c457f) {
    throw StateError('invalid ELF');
  }
  final phoff = data.getUint32(28, Endian.little);
  final phsize = data.getUint16(42, Endian.little);
  final count = data.getUint16(44, Endian.little);
  for (var i = 0; i < count; i++) {
    final p = phoff + phsize * i;
    if (data.getUint32(p, Endian.little) != 1) continue;
    final off = data.getUint32(p + 4, Endian.little);
    final addr = data.getUint32(p + 8, Endian.little);
    final fsz = data.getUint32(p + 16, Endian.little);
    final msz = data.getUint32(p + 20, Endian.little);
    bus.ram.fillRange(addr, addr + msz, 0);
    bus.ram.setRange(addr, addr + fsz, bytes, off);
  }
  cpu.jumpTo(data.getUint32(24, Endian.little));
}

void main(List<String> args) {
  final filename = args.isNotEmpty ? args.first : 'ps2_ee_physics_smoke_ee.elf';
  final bus = Ps2Bus();
  final cpu = R5900(bus);
  loadElf(filename, bus, cpu);
  final counts = <int, int>{};
  while (bus.read32(_result + 4) == 0 && cpu.clocks < 10000000) {
    final pc = cpu.pc;
    counts.update(pc, (v) => v + 1, ifAbsent: () => 1);
    if (!cpu.step()) throw StateError('unexpected MIPS opcode at 0x${pc.toRadixString(16)}');
  }
  print('PROFILE clocks=${cpu.clocks} frames=${bus.read32(_result + 8)} status=${bus.read32(_result + 4)}');
  final ranked = counts.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
  for (final e in ranked.take(25)) {
    print('HOT_PC 0x${e.key.toRadixString(16)} count=${e.value} opcode=0x${bus.read32(e.key).toRadixString(16)}');
  }
  // The PC list is taken from actual physics inner loops. Branch boundaries
  // are included alongside FPU/math and contiguous RAM-access regions.
  final starts = <int>[
    0x100460, 0x100498, 0x1004f8,
    0x100508, 0x100624, 0x1007f0,
    0x10081c, 0x1008fc, 0x1009f8, 0x100a20,
    0x100a4c, 0x100a70, 0x100a80,
  ];
  final mem = ByteData.sublistView(bus.ram);
  final translator = R5900Translator(
    fetch: (pc) => pc < _base || pc >= _end || pc & 3 != 0
        ? null : mem.getUint32(pc, Endian.little),
    protect: (_) {},
  );
  for (final pc in starts) {
    final block = translator.translate(pc, tag: 1);
    if (block == null) {
      print('DUMP_SKIP pc=0x${pc.toRadixString(16)}');
      continue;
    }
    final optimized = optimizeIrBlock(block);
    final env = _DumpEnv();
    final bytes = X64Backend.compile(optimized, 0x100010000, env);
    final out = 'physics_x64_${pc.toRadixString(16)}.bin';
    File(out).writeAsBytesSync(bytes);
    final histogram = <String, int>{};
    for (final inst in optimized.insts) {
      histogram.update(inst.op.name, (v) => v + 1, ifAbsent: () => 1);
    }
    final selected = histogram.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
    print('DUMP pc=0x${pc.toRadixString(16)} guestInstructions=${optimized.cost} ir=${optimized.insts.length} '
      'guards=${optimized.guards.length} nativeBytes=${bytes.length} file=$out '
      'topOps=${selected.take(12).map((e)=>"${e.key}:${e.value}").join(",")}');
  }
}
