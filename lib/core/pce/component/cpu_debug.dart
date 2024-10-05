// Dart imports:
import 'dart:core';

// Project imports:
import '../../../util.dart';
import 'cpu.dart';
import 'cpu_disasm.dart';

extension CpuDebugger on Cpu {
  String _disasm(pc) {
    final op = read(pc);
    final d1 = read(pc + 1);
    final d2 = read(pc + 2);
    final d3 = read(pc + 3);
    final d4 = read(pc + 4);
    final d34 = d4 << 8 | d3;
    final d56 = read(pc + 6) << 8 | read(pc + 5);

    final disasm = Disasm.disasm(pc, op, d1, d2, d34: d34, d56: d56);

    final operand = Disasm.operand(op);

    final addr = switch (operand) {
      Operand.im || Operand.im16 || Operand.none => -1,
      Operand.rel || Operand.zerorel => -1,
      Operand.zp => d1 | Cpu.zeroAddr,
      Operand.zpx => (d1 + regs.x) & 0xff | Cpu.zeroAddr,
      Operand.zpy => (d1 + regs.y) & 0xff | Cpu.zeroAddr,
      Operand.abs => d1 | d2 << 8,
      Operand.absx => ((d1 | d2 << 8) + regs.x) & 0xffff,
      Operand.absy => ((d1 | d2 << 8) + regs.y) & 0xffff,
      Operand.ind16 => d1 | d2 << 8,
      Operand.zpindx => read((d1 + regs.x) & 0xff | Cpu.zeroAddr) |
          read((d1 + regs.x + 1) & 0xff | Cpu.zeroAddr) << 8,
      Operand.zpindy =>
        (read(d1 | Cpu.zeroAddr) | read((d1 + 1) & 0xff | Cpu.zeroAddr) << 8) +
            regs.y,
      Operand.zpind =>
        read(d1 | Cpu.zeroAddr) | read((d1 + 1) & 0xff | Cpu.zeroAddr) << 8,
      Operand.blk => -1,
      Operand.imzp => d2 | Cpu.zeroAddr,
      Operand.imzpx => (d2 + regs.x) & 0xff | Cpu.zeroAddr,
      Operand.imabs => d2 | d3 << 8,
      Operand.imabsx => ((d3 | d3 << 8) + regs.x) & 0xffff,
    };

    final dstValue = addr < 0x2000 ? 0 : read(addr); // avoid I/O accses
    final dst = addr < 0
        ? ""
        : addr < 0x2000
            ? "[${hex16(addr)}:IO]"
            : "[${hex16(addr)}:${hex8(dstValue)}]";

    return "$disasm$dst".padRight(47, " ");
  }

  String _mprAddr(int addr) {
    // return "${addr >> 13}:${hex8(regs.mpr[(addr >> 13) & 7])}:${hex16(addr & 0x1fff)}";
    return hex8(regs.mpr[(addr >> 13) & 7]);
  }

  String _reg() {
    return "A:${hex8(regs.a)} X:${hex8(regs.x)} Y:${hex8(regs.y)} P:${hex8(regs.p)} SP:${hex8(regs.s)}";
  }

  String trace() {
    return "${_mprAddr(regs.pc)}:${_disasm(regs.pc)} ${_reg()} cy:$cycles"
        .toUpperCase();
  }

  String dumpDisasm(int addr, {toAddrOffset = 0x200}) {
    var result = "";
    for (var pc = addr; pc < addr + toAddrOffset;) {
      result += "${_mprAddr(addr)}:${_disasm(pc)} ";
      pc += Disasm.nextPC(read(pc));
    }
    return result;
  }

  String dumpNesTest() {
    // final ppuCycle = cycle * 3;
    // final ppuScanline = (ppuCycle ~/ 341).toString().padLeft(3, " ");
    // final ppuHorizontalCycle = (ppuCycle % 341).toString().padLeft(3, " ");

    final result = "${_mprAddr(regs.pc)}:${_disasm(regs.pc)} ${_reg()}";
    return result.toUpperCase();
  }

  String dump(
      {showIRQVector = false,
      showRegs = false,
      showZeroPage = false,
      showStack = false}) {
    const header = "bk:addr: +0 +1 +2 +3 +4 +5 +6 +7 +8 +9 +a +b +c +d +e +f\n";

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
