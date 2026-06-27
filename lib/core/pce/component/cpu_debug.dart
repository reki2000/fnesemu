// Dart imports:
import 'dart:core';

// Project imports:
import 'package:fnesemu/util/int.dart';

import '../../types.dart';
import 'cpu.dart';
import 'cpu_disasm.dart';

extension CpuDebugger on Cpu {
  String _disasm(pc) {
    final op = read(pc);
    final d1 = read(pc + 1);
    final d2 = read(pc + 2);
    final d3 = read(pc + 3);
    final d4 = read(pc + 4);
    final d34 = d4.shl8 | d3;
    final d56 = read(pc + 6).shl8 | read(pc + 5);

    final disasm = Disasm.disasm(pc, op, d1, d2, d34: d34, d56: d56);

    final operand = Disasm.operand(op);

    final addr = switch (operand) {
      Operand.im || Operand.im16 || Operand.none => -1,
      Operand.rel || Operand.zerorel || Operand.blk => -1,
      Operand.zp => d1 | Cpu.zeroAddr,
      Operand.zpx => (d1 + regs.x) & 0xff | Cpu.zeroAddr,
      Operand.zpy => (d1 + regs.y) & 0xff | Cpu.zeroAddr,
      Operand.abs => d1 | d2.shl8,
      Operand.absx => ((d1 | d2.shl8) + regs.x) & 0xffff,
      Operand.absy => ((d1 | d2.shl8) + regs.y) & 0xffff,
      Operand.ind16 => d1 | d2.shl8,
      Operand.zpindx => readzp(d1 + regs.x) | readzp(d1 + regs.x + 1).shl8,
      Operand.zpindy => (readzp(d1) | readzp(d1 + 1).shl8) + regs.y,
      Operand.zpind => readzp(d1) | readzp(d1 + 1).shl8,
      Operand.imzp => d2 | Cpu.zeroAddr,
      Operand.imzpx => (d2 + regs.x) & 0xff | Cpu.zeroAddr,
      Operand.imabs => d2 | d3.shl8,
      Operand.imabsx => ((d2 | d3.shl8) + regs.x) & 0xffff,
    };

    final dstValue = addr < 0x2000 ? 0 : read(addr); // avoid I/O accses
    final dst = addr < 0
        ? ""
        : addr < 0x2000
            ? "[${addr.x4}:IO]"
            : operand != Operand.ind16
                ? "[${addr.x4}:${dstValue.x2}]"
                : "[${addr.x4}:${read(addr + 1).x2}${dstValue.x2}]";

    return "$disasm$dst".padRight(47, " ");
  }

  int _mprAddr(int addr) {
    return regs.mpr[addr.shr13 & 7];
  }

  String _reg() {
    return "A:${regs.a.x2} X:${regs.x.x2} Y:${regs.y.x2} P:${regs.p.x2} SP:${regs.s.x2}";
  }

  TraceLog trace() {
    final bank = _mprAddr(regs.pc);
    final pc = bank.shl16 | regs.pc;
    return TraceLog(
        pc,
        cycles,
        "${bank.x2}-${_disasm(regs.pc)}".toUpperCase(),
        _reg().toUpperCase(),
        [regs.a, regs.x, regs.y, regs.p, regs.s]);
  }

  String dumpDisasm(int addr) {
    return "${_mprAddr(addr).x2}-${_disasm(addr)} ".toUpperCase();
  }

  String dumpNesTest() {
    // final ppuCycle = cycle * 3;
    // final ppuScanline = (ppuCycle ~/ 341).toString().padLeft(3, " ");
    // final ppuHorizontalCycle = (ppuCycle % 341).toString().padLeft(3, " ");

    final result = "${_mprAddr(regs.pc).x2}-${_disasm(regs.pc)} ${_reg()}";
    return result.toUpperCase();
  }

  String dump(
      {showIRQVector = false,
      showRegs = false,
      showZeroPage = false,
      showStack = false}) {
    const header = "bk-addr: +0 +1 +2 +3 +4 +5 +6 +7 +8 +9 +a +b +c +d +e +f\n";

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

    String mpr = "mpr: ${regs.mpr.map((e) => e.x2).join(" ")} ";
    String irq =
        "irq: ${holdIrq1 ? "1" : "-"} ${holdIrq2 ? "2" : "-"} ${holdTirq ? "T" : "-"} ";

    return "${showRegs ? code : ""}${mem.isNotEmpty ? ("$mpr$irq\n$header") : ''}$mem";
  }

  String dumpMem(int addr, int target) {
    addr &= 0xfff0;
    var str = "${_mprAddr(addr).x2}-${addr.x4}:";
    for (int i = 0; i < 16; i++) {
      str += ((addr + i) == target
              ? "["
              : (addr + i) == target + 1 && i != 0
                  ? "]"
                  : " ") +
          read(addr + i).x2;
    }
    return "$str\n";
  }
}
