// Dart imports:
import 'dart:core';

// Project imports:
import 'cpu.dart';
import 'disasm.dart';
import 'util.dart';

extension CpuDebugger on Cpu {
  static String _debugLog = "";

  static void clearDebugLog() {
    _debugLog = "";
  }

  void debugLog() {
    _debugLog += dumpNesTest() + "\n";
  }

  String dumpDebugLog() {
    return _debugLog;
  }

  String dumpDisasm(int addr, {toAddrOffset = 0x200}) {
    var result = "";
    for (var pc = addr; pc < addr + toAddrOffset;) {
      final op = read(pc);
      final a = read(pc + 1);
      final b = read(pc + 2);
      result += disasm(pc, op, a, b).padRight(47, " ") + "\n";
      pc += nextPC(op);
    }
    return result;
  }

  String dumpNesTest() {
    final op = read(regs.PC);
    final a = read(regs.PC + 1);
    final b = read(regs.PC + 2);

    final asm = disasm(regs.PC, op, a, b).padRight(47, " ");
    final reg =
        "A:${hex8(regs.A)} X:${hex8(regs.X)} Y:${hex8(regs.Y)} P:${hex8(regs.P)} SP:${hex8(regs.S)}";

    final ppuCycle = cycle * 3;
    final ppuScanline = (ppuCycle ~/ 341).toString().padLeft(3, " ");
    final ppuHorizontalCycle = (ppuCycle % 341).toString().padLeft(3, " ");

    return "$asm $reg PPU:$ppuScanline,$ppuHorizontalCycle CYC:$cycle"
        .toUpperCase();
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
      for (int i = 0; i < 16; i++) {
        mem += dumpMem(i * 16, 0xffff);
      }
    }
    if (showStack) {
      final base = (regs.S & 0xf0) | 0x100;
      for (int i = 0; i < 2; i++) {
        mem += dumpMem(base - 16 + i * 16, regs.S | 0x100);
      }
    }

    return "${showRegs ? code : ""}${mem.isNotEmpty ? header : ''}$mem";
  }

  String dumpMem(int addr, int target) {
    addr &= 0xfff0;
    var str = hex16(addr) + ":";
    for (int i = 0; i < 16; i++) {
      str += ((addr + i) == target
              ? "["
              : (addr + i) == target + 1 && i != 0
                  ? "]"
                  : " ") +
          hex8(read(addr + i));
    }
    return str + "\n";
  }
}
