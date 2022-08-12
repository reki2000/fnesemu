// Dart imports:
import 'dart:core';

// Project imports:
import 'cpu.dart';
import '../disasm.dart';
import '../util.dart';

class RingBuffer {
  final List<String> _buf;
  int _index = 0;
  bool _skipped = false;
  bool _recovered = false;

  RingBuffer(int size) : _buf = List.filled(size, "");

  void _add(String item) {
    _buf[_index] = item;
    _index++;
    if (_index == _buf.length) {
      _index = 0;
    }
  }

  bool addOnlyNewItem(String item) {
    if (!_buf.contains(item)) {
      _add(item);
      if (_skipped) {
        _recovered = true;
      } else {
        _recovered = false;
      }
      _skipped = false;
      return true;
    }
    _recovered = false;
    _skipped = true;
    return false;
  }

  bool get recovered => _recovered;
}

extension CpuDebugger on Cpu {
  static String _debugLog = "";
  static final ringBuffer = RingBuffer(10);

  static void clearDebugLog() {
    _debugLog = "";
  }

  void debugLog() {
    final log = dumpNesTest();
    // check redundancy of the first 73 chars which represents the CPU state
    // C78C  10 FB     BPL $C789                       A:00 X:00 Y:00 P:32 SP:FD
    // change of X or Y is ignored for X,Y are often used as a loop counter
    final state = log.substring(0, 74);
    if (ringBuffer.addOnlyNewItem(state.replaceRange(53, 63, "          "))) {
      if (ringBuffer.recovered) {
        _debugLog += "...supress...\n";
      }
      _debugLog += state + "\n";
    }
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
