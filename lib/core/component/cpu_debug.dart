// Dart imports:
import 'dart:core';

// Project imports:
import '../../util.dart';
import 'cpu.dart';
import 'cpu_disasm.dart';

extension CpuDebugger on Cpu {
  String trace() {
    final op = read(regs.pc);
    final a = read(regs.pc + 1);
    final b = read(regs.pc + 2);

    final asm = Disasm.disasm(regs.pc, op, a, b).padRight(47, " ");
    final reg =
        "A:${hex8(regs.a)} X:${hex8(regs.x)} Y:${hex8(regs.y)} P:${hex8(regs.p)} SP:${hex8(regs.s)}";

    return "$asm $reg".toUpperCase();
  }

  String dumpDisasm(int addr, {toAddrOffset = 0x200}) {
    var result = "";
    for (var pc = addr; pc < addr + toAddrOffset;) {
      final op = read(pc);
      final a = read(pc + 1);
      final b = read(pc + 2);
      result += "${Disasm.disasm(pc, op, a, b).padRight(47, " ")}\n";
      pc += Disasm.nextPC(op);
    }
    return result;
  }

  String dumpNesTest() {
    final op = read(regs.pc);
    final a = read(regs.pc + 1);
    final b = read(regs.pc + 2);

    final asm = Disasm.disasm(regs.pc, op, a, b).padRight(47, " ");
    final reg =
        "A:${hex8(regs.a)} X:${hex8(regs.x)} Y:${hex8(regs.y)} P:${hex8(regs.p)} SP:${hex8(regs.s)}";

    final ppuCycle = cycle * 3;
    final ppuScanline = (ppuCycle ~/ 341).toString().padLeft(3, " ");
    final ppuHorizontalCycle = (ppuCycle % 341).toString().padLeft(3, " ");

    final result = "$asm $reg PPU:$ppuScanline,$ppuHorizontalCycle CYC:$cycle";
    return result.toUpperCase();
  }

  String dump(
      {showIRQVector = false,
      showRegs = false,
      showZeroPage = false,
      showStack = false}) {
    final code = dumpNesTest();
    // for (int i = -1; i < 2; i++) {
    //   code += dumpMem(regs.PC + i * 16, regs.PC);
    // }

    String mem = "";
    const header = "addr: +0 +1 +2 +3 +4 +5 +6 +7 +8 +9 +a +b +c +d +e +f\n";

    if (showIRQVector) {
      mem += dumpMem(0xfff0, 0x0000);
    }

    if (showZeroPage) {
      for (int i = 0; i < 8; i++) {
        mem += dumpMem(i * 16, 0xffff);
      }
    }
    if (showStack) {
      final base = (regs.s & 0xf0) | 0x100;
      for (int i = 0; i < 2; i++) {
        mem += dumpMem(base - 16 + i * 16, regs.s | 0x100);
      }
    }

    return "${showRegs ? code : ""}${mem.isNotEmpty ? header : ''}$mem";
  }

  String dumpMem(int addr, int target) {
    addr &= 0xfff0;
    var str = "${hex16(addr)}:";
    for (int i = 0; i < 16; i++) {
      str += ((addr + i) == target
              ? "["
              : (addr + i) == target + 1 && i != 0
                  ? "]"
                  : " ") +
          hex8(read(addr + i));
    }
    return "$str\n";
  }
}
