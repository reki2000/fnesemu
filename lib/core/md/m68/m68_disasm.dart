import 'dart:io';

import 'package:fnesemu/util/int.dart';

extension IntBit on int {
  bool bit(int n) => (this & (1 << n)) != 0;
}

class Disasm {
  int op = 0;

  String opBit(int op) => ["btst", "bchg", "bclr", "bset"][op];

  String opRot(int op, bool l) =>
      ["as", "ls", "ro", "rox"][op] + (l ? "l" : "r");

  String opLog(int op) =>
      ["or", "and", "sub", "add", "-", "eor", "cmp"][op >> 1];

  String opSubCmpAdd(int op) => ["sub", "cmp", "add", "-"][op >> 1 & 3];

  String sz0(int s) => ["b", "w", "l", "-"][s];
  String sz1(bool s) => s ? "l" : "w";

  String ex([msg = ""]) => throw ("Unknown opcode: ${op.hex16} $msg");

  (String, int) disasm(List<int> data, int pc) {
    int addr = 0;
    pc += 2;
    int fetch() => data[addr++];

    op = fetch();

    final op0 = op >> 12 & 0x0f;
    final op1 = op >> 8 & 0x0f;
    final op2 = op >> 4 & 0x0f;
    final op3 = op & 0x0f;
    final op23 = op & 0xff;

    final modreg = op & 0x3f;
    final mod = modreg >> 3 & 7;
    final r1 = modreg >> 0 & 7;
    final r2 = op >> 9 & 7;
    final size = op >> 6 & 3;
    final size2 = switch (op >> 12 & 3) { 1 => 0, 3 => 1, 2 => 2, _ => 3 };

    final cond = [
      "t", "f", "hi", "ls", "cc", "cs", "ne", "eq", //
      "vc", "vs", "pl", "mi", "ge", "lt", "gt", "le" //
    ][op1];

    final sz = sz0(size);

    String im([int? s]) => switch (s ?? size) {
          0 => fetch().hex8,
          1 => fetch().hex16,
          2 => (fetch() << 16 | fetch()).hex32,
          _ => ex("im size: $s"),
        };

    String eaEx(String base) {
      final breaf = data[pc++];
      final disp = breaf & 0xff;
      final reg = breaf >> 12 & 7;
      final size = sz1(breaf.bit(11));
      final regType = breaf.bit(15) ? "a" : "d";
      return "(#${disp.hex16}, $base, $regType$reg.$size)";
    }

    String ea([int? s, int? m, int? r]) {
      s = s ?? size;
      m = m ?? mod;
      r = r ?? r1;
      return switch (m) {
        0 => "d$r",
        1 => "a$r",
        2 => "(a$r)",
        3 => "(a$r)+",
        4 => "-(a$r)",
        5 => "(#${im(1)}, a$r)",
        6 => eaEx("a$r"),
        7 => switch (r) {
            0 => "(#${im(1)})",
            1 => "(#${im(2)})",
            2 => "(#${im(s)}, pc)",
            3 => eaEx("pc"),
            4 => "#${im(s)}",
            _ => ex("s:$s m:$m r:$r"),
          },
        _ => ex("s:$s m:$m r:$r"),
      };
    }

    String pcRel(int disp) =>
        (pc + (disp == 0 ? fetch().rel16 : disp.rel8)).hex24;

    final asm = switch (op0) {
      0x0 => switch (op1) {
          0x0 ||
          0x2 ||
          0xa when modreg == 0x3c =>
            "${opLog(op1)}i.$sz #${im(1)}, ${size == 0 ? "ccr" : "sr"}",
          0x0 ||
          0x2 ||
          0x4 ||
          0x6 ||
          0xa ||
          0xc =>
            "${opLog(op1)}i.$sz #${im()}, ${ea()}",
          0x8 => "${opBit(size)} #${im(0)}, ${ea()}",
          _ => mod == 1
              ? "movep.${sz1(op.bit(6))} ${op.bit(7) ? "d$r2, a$r1" : "a$r1, d$r2"}"
              : "${opBit(size)} d$r2, ${ea()}",
        },
      0x1 ||
      0x2 ||
      0x3 =>
        "move.${sz0(size2)} ${ea(size2)}, ${ea(size2, op >> 6 & 7, r2)}",
      0x4 => switch (op1) {
          _ when op & 0x1c0 == 0x180 => "chk.w d$r2, ${ea(1)}",
          _ when op & 0x1c0 == 0x1c0 => "lea.l ${ea(2)}, a$r2",
          _ when op & 0xb80 == 0x880 =>
            "movem.${sz1(size.bit0)} ${ea()}, #${im(1)}",
          _ when op & 0xfc0 == 0x0c0 => "move.w sr, ${ea(1)}",
          _ when op & 0xfc0 == 0x4c0 => "move.b ${ea(0)}, ccr",
          _ when op & 0xfc0 == 0x6c0 => "move.w ${ea(1)}, sr",
          0x0 => "negx.$sz ${ea()}",
          0x2 => "clr.$sz ${ea()}",
          0x4 => "neg.$sz ${ea()}",
          0x6 => "not.$sz ${ea()}",
          0x8 when size == 0 => "nbcd.b ${ea(0)}",
          0x8 when size == 1 && mod == 0 => "swap.w d$r1",
          0x8 when size == 1 => "pea.l ${ea(2)}",
          0x8 => "ext.${sz1(size.bit0)} d$r1",
          0xa when op23 == 0xfc => "illegal",
          0xa when size == 3 => "tas.b ${ea()}",
          0xa => "tst.$sz ${ea()}",
          0xe => switch (op2) {
              0x4 => "trap #${(op3 & 0xf).hex8}",
              0x5 when !mod.bit0 => "link.w a$r1, #${im(1)}",
              0x5 => "unlk a$r1",
              0x6 => "move.l ${mod.bit0 ? "usp, a$r1" : "a$r1, usp"}",
              0x7 => switch (op3) {
                  0x0 => "reset",
                  0x1 => "nop",
                  0x2 => "stop #${im(1)}",
                  0x3 => "rte",
                  0x4 => "rtd #${im(1)}",
                  0x5 => "rts",
                  0x6 => "trapv",
                  0x7 => "rtr",
                  _ => ex(),
                },
              _ when op23 & 0xc0 == 0x80 => "jsr ${ea(2)}",
              _ => "jmp ${ea(2)}",
            },
          _ => ex("op0 0x4"),
        },
      0x5 when size == 3 && mod == 1 => "db$cond.w d$r1, #${pcRel(0)}",
      0x5 when size == 3 => "s$cond.b, ${ea(2)}",
      0x5 when op1.bit0 => "subq.$sz #$r2, ${ea()}",
      0x5 => "addq.$sz #$r2, ${ea()}",
      0x6 when op1 == 0x00 => "bra #${pcRel(op23)}",
      0x6 when op1 == 0x01 => "bsr #${pcRel(op23)}",
      0x6 => "b$cond #${pcRel(op23)}",
      0x7 => "moveq.l #${op23.hex8}, d$r2",
      0x8 when op & 0x1c0 == 0xc0 => "divu.w d$r2, ${ea(1)}",
      0x8 when op & 0x1c0 == 0x1c0 => "divs.w d$r2, ${ea(1)}",
      0x8 when op & 0x1f0 == 0x100 =>
        "sbcd.b d$r2, ${mod.bit0 ? "-(a$r1)" : "d$r1"}",
      0x8 => "or.$sz ${op1.bit0 ? "d$r2, ${ea()}" : "${ea()}, d$r2"}",
      0x9 ||
      0xb ||
      0xd when op & 0xc0 == 0xc0 =>
        "${opSubCmpAdd(op0)}a.${sz1(op1.bit0)} ${ea(op1.bit0 ? 2 : 1)}, a$r2",
      0xb when op & 0x138 == 0x10b => "cmpm.$sz a$r1, a$r2",
      0xb when op & 0x100 == 0x100 => "eor.$sz d$r2, ${ea()}",
      0x9 ||
      0xd when op & 0x130 == 0x100 =>
        "${opSubCmpAdd(op0)}x.$sz d$r2, ${mod.bit0 ? "-(a$r1)" : "d$r1"}",
      0x9 ||
      0xb ||
      0xd =>
        "${opSubCmpAdd(op0)}.$sz ${op1.bit0 ? "${ea()}, d$r2" : "d$r2, ${ea()}"}",
      0xc when op & 0x1c0 == 0xc0 => "mulu.w d$r2, ${ea(1)}",
      0xc when op & 0x1c0 == 0x1c0 => "muls.w d$r2, ${ea(1)}",
      0xc when op & 0x1f0 == 0x100 =>
        "abcd.b d$r2, ${mod.bit0 ? "-(a$r1)" : "d$r1"}",
      0xc when op & 0x130 == 0x100 =>
        "exg.w d$r2, ${ea(2, size << 1 | mod, r1)}",
      0xc => "and.$sz ${op1.bit0 ? "d$r2, ${ea()}" : "${ea()}, d$r2"}",
      0xe when op3 & 0xc0 == 0xc0 =>
        "${opRot(op1 >> 1, op1.bit0)}.w #1, ${ea()}",
      0xe =>
        "${opRot(op >> 3 & 3, op1.bit0)}.$sz ${op.bit(5) ? "d$r2" : "#$r2"}, d$r1",
      _ => ex("op0"),
    };

    return (asm, addr);
  }
}

int main(List<String> args) {
  Disasm disasm = Disasm();

  final data = args.map((e) => int.parse(e, radix: 16)).toList();
  final (inst, size) = disasm.disasm(data, 0);

  print(inst);
  print(size.toString());

  return 0;
}

void print(String msg) {
  stdout.writeln(msg);
}
