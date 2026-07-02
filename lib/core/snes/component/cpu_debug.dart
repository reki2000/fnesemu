import 'package:fnesemu/util/int.dart';

import '../../types.dart';
import 'cpu.dart';
import 'cpu_disasm.dart';

extension CpuDebugger on Cpu {
  String _regStr() {
    final c = regs.p.bit0 ? "C" : "c";
    final z = regs.p.bit1 ? "Z" : "z";
    final i = regs.p.bit2 ? "I" : "i";
    final d = regs.p.bit3 ? "D" : "d";
    final x = regs.p.bit4 ? "X" : "x";
    final m = regs.p.bit5 ? "M" : "m";
    final v = regs.p.bit6 ? "V" : "v";
    final n = regs.p.bit7 ? "N" : "n";
    final e = regs.e ? "E" : "e";
    return "A:${regs.a.x4} X:${regs.x.x4} Y:${regs.y.x4} "
        "S:${regs.s.x4} D:${regs.d.x4} DB:${regs.dbr.x2} "
        "P:$n$v$m$x$d$i$z$c $e";
  }

  TraceLog trace() {
    final addr = regs.pbr.shl16 | regs.pc;
    final (asm, _) = _disasmAt(addr);
    return TraceLog(
      regs.pc,
      cycle,
      asm.padRight(20).toUpperCase(),
      _regStr().toUpperCase(),
      [regs.a, regs.x, regs.y, regs.s, regs.p, regs.e ? 1 : 0],
    );
  }

  (String, int) dumpDisasm(int addr) {
    final (asm, next) = _disasmAt(addr);
    return (asm.padRight(20).toUpperCase(), addr + next);
  }

  (String, int) _disasmAt(int addr) {
    final op = peek(addr);
    final a = peek(addr + 1);
    final b = peek(addr + 2);
    final c = peek(addr + 3);
    return Disasm.disasm(addr.mask16, op, a, b, c, mSize, xSize);
  }

  String dump({bool showStack = false}) {
    final (asm, _) = _disasmAt(regs.pbr.shl16 | regs.pc);
    var s = "${regs.pbr.x2}:${regs.pc.x4} ${asm.padRight(20)}  ${_regStr()}\n";
    if (showStack) {
      final base = regs.s & 0xfff0;
      for (int row = 0; row < 2; row++) {
        s += "${(base + row * 16).x4}:";
        for (int i = 0; i < 16; i++) {
          s += " ${peek(base + row * 16 + i).x2}";
        }
        s += "\n";
      }
    }
    return s;
  }
}
