import 'dart:io';

import 'package:fnesemu/util/int.dart';

class Z80Disasm {
  static (String, int) disasm(List<int> data, int pc) {
    int addr = 0;
    int fetch() => data[addr++];

    const regs8 = ["b", "c", "d", "e", "h", "l", "(hl)", "a"];
    const regs16 = ["bc", "de", "hl", "sp"];
    const cond = ["nz", "nc", "po", "p", "z", "c", "pe", "m"];
    const ari = ["add a,", "adc a,", "sub", "sbc a,", "and", "xor", "or", "cp"];
    const rot = ["rlc", "rrc", "rl", "rr", "sla", "sra", "sll", "srl"];
    const op07 = ["rlca", "rrca", "rla", "rra", "daa", "cpl", "scf", "ccf"];

    final op = fetch();

    String rel8() {
      final d = fetch();
      return "${(d - (d >= 128 ? 256 : 0) + pc + addr).hex16}h";
    }

    String im8() => "${fetch().hex8}h";
    String im16() => "${(fetch() | fetch() << 8).hex16}h";

    final regLd8 = regs8[op >> 3 & 7];
    final regLd16 = regs16[op >> 4 & 3];
    final reg8 = regs8[op & 7];

    String opCb() {
      final op = fetch();
      final r8 = regs8[op & 7];
      final bit = op >> 3 & 7;
      return switch (op & 0xc0) {
        0x00 => "${rot[op >> 3 & 7]} $r8",
        0x40 => "bit $bit, $r8",
        0x80 => "res $bit, $r8",
        0xc0 => "set $bit, $r8",
        _ => throw "never reach",
      };
    }

    String opEd() {
      final op = fetch();
      final r8 = regs8[op >> 4 & 7];
      final r16 = regs16[op >> 4 & 3];
      return switch (op & 0xc0) {
        0x00 => switch (op & 0x0f) {
            0x00 || 0x08 => "in0 $r8, (c)",
            0x01 || 0x09 => "out0 (c), $r8",
            0x04 || 0x0c => "tst $r8",
            _ => throw "unknown op: ${op.hex8}",
          },
        0x40 => switch (op & 0x0f) {
            0x00 || 0x08 => "in $r8, (c)",
            0x01 || 0x09 => "out (c), $r8",
            0x02 || 0x0a => "sbc hl, $r16",
            0x03 || 0x0b => "ld ($im16()), $r16",
            0x0c => "mlt $r16",
            _ => switch (op) {
                0x44 => "neg",
                0x45 => "retn",
                0x46 => "im 0",
                0x47 => "ld i, a",
                0x4d => "reti",
                0x4f => "ld r, a",
                0x56 => "im 1",
                0x57 => "ld a, i",
                0x5e => "im 2",
                0x5f => "ld a, r",
                0x64 => "tst ${im8()}",
                0x67 => "rrd",
                0x6f => "rld",
                0x74 => "tstio ${im8()}",
                0x76 => "slp",
                _ => throw "unknown op: ${op.hex8}",
              }
          },
        _ => switch (op) {
            0x83 => "otim",
            0x8b => "otdm",
            0x93 => "otimr",
            0x9b => "otdmr",
            0xa0 => "ldi",
            0xa1 => "cpi",
            0xa2 => "ini",
            0xa3 => "outi",
            0xa8 => "ldd",
            0xa9 => "cpd",
            0xaa => "ind",
            0xab => "outd",
            0xb0 => "ldir",
            0xb1 => "cpir",
            0xb2 => "inir",
            0xb3 => "otir",
            0xb8 => "lddr",
            0xb9 => "cpdr",
            0xba => "indr",
            0xbb => "otdr",
            _ => throw "unknown op: ${op.hex8}",
          },
      };
    }

    String opDdFdCb(int op, String disp) {
      final bit = op >> 3 & 7;
      final r8 = regs8[op & 7];

      return switch (op & 0xc0) {
        0x40 => "bit $bit, $disp",
        0x80 => "res $bit, $disp",
        0xc0 => "set $bit, $disp",
        _ => "${rot[op >> 3 & 7]} $disp, $r8",
      };
    }

    String opDdFd(String xy) {
      String disp() {
        final d = fetch();
        final disp = "($xy${d > 128 ? "-${(256 - d).hex8}h" : "+${d.hex8}h"})";
        return disp;
      }

      final op = fetch();

      if (op == 0xcb) {
        return opDdFdCb(fetch(), disp());
      }

      final r8 = regs8[op & 7];

      return switch (op) {
        0x09 || 0x19 || 0x29 || 0x39 => "add $xy, ${regs16[op & 3]}",
        0x21 => "ld $xy, ${im16()}",
        0x22 => "ld (${im16()}), $xy",
        0x23 => "inc $xy",
        0x2a => "ld $xy, (${im16()})",
        0x2b => "dec $xy",
        0x34 => "inc ${disp()}",
        0x35 => "dec ${disp()}",
        0x36 => "ld ${disp()}, ${im8()}",
        0x46 ||
        0x4e ||
        0x56 ||
        0x5e ||
        0x66 ||
        0x6e ||
        0x7e =>
          "ld $r8, ${disp()}",
        0x70 ||
        0x71 ||
        0x72 ||
        0x73 ||
        0x74 ||
        0x75 ||
        0x77 =>
          "ld ${disp()}, $r8",
        0xe1 => "pop $xy",
        0xe3 => "ex (sp), $xy",
        0xe5 => "push $xy",
        0xe9 => "jp ($xy)",
        0xf9 => "ld sp, $xy",
        _ => throw "unknown op: ${op.hex8}",
      };
    }

    final asm = switch (op & 0xc0) {
      0x00 => switch (op & 0x0f) {
          0x00 || 0x08 => switch (op) {
              0x00 => "nop",
              0x08 => "ex af, af'",
              0x10 => "djnz ${rel8()}",
              0x18 => "jr ${rel8()}",
              0x20 ||
              0x30 ||
              0x28 ||
              0x38 =>
                "jr ${cond[op >> 5 & 3]}, ${rel8()}",
              _ => throw "never reach",
            },
          0x01 => "ld $regLd16, ${im16()}",
          0x09 => "add hl, $regLd16",
          0x02 => "ld ($regLd16), a",
          0x0a => "ld a, ($regLd16)",
          0x03 => "inc $regLd16",
          0x0b => "dec $regLd16",
          0x04 || 0x0c => "inc $regLd8",
          0x05 || 0x0d => "dec $regLd8",
          0x06 || 0x0e => "ld $regLd8, ${im8()}",
          0x07 || 0x0f => op07[op >> 3 & 7],
          _ => throw "never reach",
        },
      0x40 => "ld ${regs8[op >> 3 & 7]}, $reg8",
      0x80 => "${ari[op >> 3 & 7]} $reg8",
      0xc0 => switch (op & 0x0f) {
          0x00 || 0x08 => "ret ${cond[op >> 4 & 7]}",
          0x01 => "pop ${regs16[op >> 4 & 3]}",
          0x09 => ["ret", "exx", "jp (hl)", "ld sp, hl"][op >> 4 & 3],
          0x02 || 0x0a => "jp ${cond[op >> 4 & 7]}, ${im16()}",
          0x03 || 0x0b => switch (op) {
              0xc3 => "jp ${im16()}",
              0xcb => opCb(),
              _ => [
                  "out (n), a",
                  "i a, (n)",
                  "ex (sp), hl",
                  "ex de, hl",
                  "di",
                  "ei"
                ][(op >> 3 & 7) - 2],
            },
          0x04 || 0x0c => "call ${cond[op >> 4 & 7]}, ${im16()}",
          0x05 => "push ${regs16[op >> 4 & 3]}",
          0x0d => switch (op) {
              0xcd => "call ${im16()}",
              0xdd => opDdFd("ix"),
              0xed => opEd(),
              0xfd => opDdFd("iy"),
              _ => throw "never reach",
            },
          0x06 || 0x0e => "${ari[op >> 3 & 7]} ${im8()}",
          0x07 || 0x0f => "rst ${op & 0x38}h",
          _ => throw "never reach",
        },
      _ => throw "never reach",
    };

    return (asm, addr);
  }
}

int main(List<String> args) {
  final data = args.map((e) => int.parse(e, radix: 16)).toList();
  final (inst, size) = Z80Disasm.disasm(data, 0);

  _print(inst);
  _print(size.toString());

  return 0;
}

void _print(String msg) {
  stdout.writeln(msg);
}
