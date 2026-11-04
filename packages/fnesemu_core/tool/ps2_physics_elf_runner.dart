// Run the original bare-metal PS2 EE physics ELF with R5900 interpreter or
// the existing native JIT. Checks the result block written by the guest.
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/jit/ps2_jit.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';

const resultBase = 0x00200000;
const codeBase = 0x00100000;

void loadElf(Uint8List input, Ps2Bus bus, R5900 cpu) {
  final data = ByteData.sublistView(input);
  if (data.getUint32(0, Endian.little) != 0x464c457f ||
      input[4] != 1 || input[5] != 1 ||
      data.getUint16(18, Endian.little) != 8) {
    throw StateError('requires 32-bit little-endian MIPS ELF');
  }
  final phoff = data.getUint32(28, Endian.little);
  final count = data.getUint16(44, Endian.little);
  final phsize = data.getUint16(42, Endian.little);
  for (var i = 0; i < count; i++) {
    final p = phoff + i * phsize;
    if (data.getUint32(p, Endian.little) != 1) continue;
    final offset = data.getUint32(p + 4, Endian.little);
    final addr = data.getUint32(p + 8, Endian.little);
    final fileSize = data.getUint32(p + 16, Endian.little);
    final memSize = data.getUint32(p + 20, Endian.little);
    if (addr + memSize > bus.ram.length ||
        offset + fileSize > input.length || fileSize > memSize) {
      throw StateError('PT_LOAD out of range at 0x${addr.toRadixString(16)}');
    }
    bus.ram.fillRange(addr, addr + memSize, 0);
    bus.ram.setRange(addr, addr + fileSize, input, offset);
    print('ELF_LOAD addr=0x${addr.toRadixString(16)} filesz=$fileSize memsz=$memSize');
  }
  cpu.jumpTo(data.getUint32(24, Endian.little));
  print('ELF_ENTRY pc=0x${cpu.pc.toRadixString(16)}');
}

String hex(int value) => '0x${value.toUnsigned(32).toRadixString(16).padLeft(8, '0')}';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('Usage: dart run tool/ps2_physics_elf_runner.dart jit|interp /path/to/file.elf [maxGuestClocks]');
    exitCode = 2;
    return;
  }
  final useJit = args[0] == 'jit';
  if (!useJit && args[0] != 'interp') throw ArgumentError('invalid mode');
  final maxGuestClocks = args.length > 2 ? int.parse(args[2]) : 200000000;
  final jit = useJit ? Ps2Jit.create(native: true, compileThreshold: 1) : null;
  if (useJit && jit == null) throw StateError('native JIT unavailable');
  try {
    final bus = Ps2Bus(ram: jit?.ram);
    final cpu = R5900(bus, gpr: jit?.gpr, fpr: jit?.fpr);
    jit?.attach(cpu);
    final bytes = File(args[1]).readAsBytesSync();
    loadElf(bytes, bus, cpu);

    final watch = Stopwatch()..start();
    var jitClocks = 0, interpretedClocks = 0, jitCalls = 0, fallback = 0;
    var nextReport = 5000000;
    while (true) {
      final status = bus.read32(resultBase + 4);
      if (status == 1 || status == 2) {
        watch.stop();
        final fields = [for (var o = 0; o < 0x30; o += 4) bus.read32(resultBase + o)];
        print('RESULT mode=${args[0]} status=$status frames=${fields[2]} bodies=${fields[3]} '
              'pairs=${fields[4]} contacts=${fields[5]} impulses=${fields[6]} '
              'checksum=${hex(fields[7])} joints=${fields[10]} lastContacts=${fields[11]}');
        print('RESULT_FLOAT sum_y=${ByteData.sublistView(bus.ram).getFloat32(resultBase + 0x20, Endian.little)} '
              'kinetic_energy=${ByteData.sublistView(bus.ram).getFloat32(resultBase + 0x24, Endian.little)}');
        print('MEASURE guestClocks=${cpu.clocks} elapsedMs=${watch.elapsedMilliseconds} '
              'jitClocks=$jitClocks interpClocks=$interpretedClocks '
              'jitCalls=$jitCalls fallbacks=$fallback');
        if (fields[0] != 0x50535953 || status != 1 || fields[3] != 144) {
          throw StateError('invalid guest result block');
        }
        return;
      }
      if (cpu.clocks >= maxGuestClocks) {
        throw StateError('guest clock limit $maxGuestClocks reached '
          'at PC=${hex(cpu.pc)} status=$status frames=${bus.read32(resultBase + 8)}');
      }
      if (cpu.pc >= 0x1fc00000 || cpu.pc == 0xbfc00000 ||
          (cpu.pc < codeBase || cpu.pc >= 0x110000) && cpu.clocks > 0) {
        throw StateError('guest entered unexpected exception/unmapped PC=${hex(cpu.pc)}, '
          'lastOpcode=${cpu.unimplementedInstruction}, lastUnimplementedPc=${hex(cpu.unimplementedPc)}, '
          'cause=${hex(cpu.cop0[R5900.cop0Cause])}, epc=${hex(cpu.cop0[R5900.cop0Epc])}');
      }
      final before = cpu.clocks;
      if (jit != null && jit.run(4096)) {
        jitClocks += cpu.clocks - before;
        jitCalls++;
      } else {
        final stepPc = cpu.pc;
        if (!cpu.step()) {
          throw StateError('unsupported MIPS opcode at PC=${hex(stepPc)} word=${hex(bus.read32(stepPc))}');
        }
        interpretedClocks += cpu.clocks - before;
        if (jit != null) fallback++;
      }
      if (cpu.clocks >= nextReport) {
        print('PROGRESS mode=${args[0]} guestClocks=${cpu.clocks} '
          'pc=${hex(cpu.pc)} frames=${bus.read32(resultBase + 8)} '
          'status=${bus.read32(resultBase + 4)} '
          'elapsedMs=${watch.elapsedMilliseconds}');
        nextReport += 5000000;
      }
    }
  } finally {
    jit?.dispose();
  }
}
