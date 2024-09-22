// Dart imports:
import 'dart:core';

// Project imports:
import '../../util.dart';
import 'cpu.dart';
import 'cpu_disasm.dart';

extension CpuDebugger on Cpu {
  String _disasm(pc) {
    final op = read(pc);
    final pc1 = read(pc + 1);
    final pc2 = read(pc + 2);
    final pc34 = read(pc + 4) << 8 | read(pc + 3);
    final pc56 = read(pc + 6) << 8 | read(pc + 5);
    return Disasm.disasm(pc, op, pc1, pc2, c: pc34, d: pc56).padRight(47, " ");
  }

  String _mprAddr(int addr) {
    return "${addr >> 13}:${hex8(regs.mpr[(addr >> 13) & 7])}:${hex16(addr & 0x1fff)}";
  }

  String _reg() {
    return "A:${hex8(regs.a)} X:${hex8(regs.x)} Y:${hex8(regs.y)} P:${hex8(regs.p)} SP:${hex8(regs.s)}";
  }

  String trace() {
    return "${_disasm(regs.pc)} ${_reg()} cy:$cycles".toUpperCase();
  }

  String dumpDisasm(int addr, {toAddrOffset = 0x200}) {
    var result = "";
    for (var pc = addr; pc < addr + toAddrOffset;) {
      result += "${_mprAddr(addr)}: ${_disasm(pc)} ";
      pc += Disasm.nextPC(read(pc));
    }
    return result;
  }

  String dumpNesTest() {
    // final ppuCycle = cycle * 3;
    // final ppuScanline = (ppuCycle ~/ 341).toString().padLeft(3, " ");
    // final ppuHorizontalCycle = (ppuCycle % 341).toString().padLeft(3, " ");

    final result = "${_mprAddr(regs.pc)} ${_disasm(regs.pc)} ${_reg()}";
    return result.toUpperCase();
  }

  String dump(
      {showIRQVector = false,
      showRegs = false,
      showZeroPage = false,
      showStack = false}) {
    const header =
        "addr:           +0 +1 +2 +3 +4 +5 +6 +7 +8 +9 +a +b +c +d +e +f\n";

    String mem = "";

    if (showIRQVector) {
      mem += dumpMem(0xfff0, 0x0000);
    }

    if (showZeroPage) {
      for (int i = 0; i < 8; i++) {
        mem += dumpMem(i * 16 | 0x2000, 0xffff);
      }
    }

    if (showStack) {
      final base = (regs.s & 0xf0) | 0x2100;
      for (int i = 0; i < 2; i++) {
        mem += dumpMem(base - 16 + i * 16, regs.s | 0x2100);
      }
    }

    // final pcMem =
    //     "${dumpMem(regs.pc & 0xfff0, regs.pc)}${dumpMem((regs.pc + 16) & 0xfff0, regs.pc)}";

    final code = "${dumpNesTest()} cy:$cycles\n";

    String mpr = "mpr: ${regs.mpr.map((e) => hex8(e)).join(" ")} ";
    String irq =
        "irq: ${holdIrq1 ? "1" : "-"} ${holdIrq2 ? "2" : "-"} ${holdTirq ? "T" : "-"} ";

    return "${showRegs ? code : ""}${mem.isNotEmpty ? ("$mpr$irq\n$header") : ''}$mem";
  }

  String dumpMem(int addr, int target) {
    addr &= 0xfff0;
    var str = "${_mprAddr(addr)} ${hex16(addr)}:";
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
