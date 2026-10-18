import '../../../types.dart';
import '../../../util/int.dart';

/// disassembles the V30MZ instruction at [ip] with the [read] function
/// returning the bytes from the instruction. returns the text and length
(String, int) disasmV30(int Function(int offset) read, int ip) {
  var pos = 0;
  int u8() => read(pos++);
  int s8() => u8().rel8;
  int u16() {
    final v = u8();
    return v | u8().shl8;
  }

  const r8 = ["al", "cl", "dl", "bl", "ah", "ch", "dh", "bh"];
  const r16 = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"];
  const sreg = ["es", "cs", "ss", "ds"];
  const ea = ["bx+si", "bx+di", "bp+si", "bp+di", "si", "di", "bp", "bx"];
  const alu = ["add", "or", "adc", "sbb", "and", "sub", "xor", "cmp"];
  const shifts = ["rol", "ror", "rcl", "rcr", "shl", "shr", "shl", "sar"];
  const cc = [
    "o", "no", "c", "nc", "z", "nz", "be", "a", //
    "s", "ns", "pe", "po", "l", "ge", "le", "g"
  ];

  var prefix = "";
  var seg = "";
  var op = u8();
  while (true) {
    if (op == 0x26 || op == 0x2e || op == 0x36 || op == 0x3e) {
      seg = "${sreg[(op >> 3) & 3]}:";
    } else if (op == 0xf2) {
      prefix = "repne ";
    } else if (op == 0xf3) {
      prefix = "rep ";
    } else if (op == 0xf0) {
      prefix = "lock ";
    } else {
      break;
    }
    if (pos > 4) break;
    op = u8();
  }

  var reg = 0;
  String modrm(bool word) {
    final b = u8();
    final mod = b >> 6, rm = b & 7;
    reg = (b >> 3) & 7;
    if (mod == 3) return word ? r16[rm] : r8[rm];
    final size = word ? "word " : "byte ";
    if (mod == 0 && rm == 6) return "$size$seg[${u16().x4}]";
    final disp = mod == 1
        ? s8()
        : mod == 2
            ? u16().rel16
            : 0;
    final d = disp == 0
        ? ""
        : disp < 0
            ? "-${(-disp).x2}"
            : "+${disp.x2}";
    return "$size$seg[${ea[rm]}$d]";
  }

  String rel(int offset) => (ip + pos + offset).mask16.x4;

  final word = op.bit0;
  final text = switch (op) {
    < 0x40 when op & 7 < 6 => switch (op & 7) {
        0 || 1 => () {
            final m = modrm(word);
            return "${alu[op >> 3]} $m, ${word ? r16[reg] : r8[reg]}";
          }(),
        2 || 3 => () {
            final m = modrm(word);
            return "${alu[op >> 3]} ${word ? r16[reg] : r8[reg]}, $m";
          }(),
        4 => "${alu[op >> 3]} al, ${u8().x2}",
        _ => "${alu[op >> 3]} ax, ${u16().x4}",
      },
    0x06 || 0x0e || 0x16 || 0x1e => "push ${sreg[op >> 3]}",
    0x07 || 0x17 || 0x1f => "pop ${sreg[op >> 3]}",
    0x27 => "daa",
    0x2f => "das",
    0x37 => "aaa",
    0x3f => "aas",
    >= 0x40 && <= 0x47 => "inc ${r16[op & 7]}",
    >= 0x48 && <= 0x4f => "dec ${r16[op & 7]}",
    >= 0x50 && <= 0x57 => "push ${r16[op & 7]}",
    >= 0x58 && <= 0x5f => "pop ${r16[op & 7]}",
    0x60 => "pusha",
    0x61 => "popa",
    0x62 => () {
        final m = modrm(true);
        return "bound ${r16[reg]}, $m";
      }(),
    0x68 => "push ${u16().x4}",
    0x6a => "push ${s8().mask16.x4}",
    0x69 || 0x6b => () {
        final m = modrm(true);
        final imm = op == 0x69 ? u16() : s8().mask16;
        return "imul ${r16[reg]}, $m, ${imm.x4}";
      }(),
    0x6c => "${prefix}insb",
    0x6d => "${prefix}insw",
    0x6e => "${prefix}outsb",
    0x6f => "${prefix}outsw",
    >= 0x70 && <= 0x7f => () {
        final d = s8();
        return "j${cc[op & 15]} ${rel(d)}";
      }(),
    >= 0x80 && <= 0x83 => () {
        final m = modrm(word);
        final imm = op == 0x81
            ? u16().x4
            : op == 0x83
                ? s8().mask16.x4
                : u8().x2;
        return "${alu[reg]} $m, $imm";
      }(),
    0x84 || 0x85 => () {
        final m = modrm(word);
        return "test $m, ${word ? r16[reg] : r8[reg]}";
      }(),
    0x86 || 0x87 => () {
        final m = modrm(word);
        return "xchg $m, ${word ? r16[reg] : r8[reg]}";
      }(),
    0x88 || 0x89 => () {
        final m = modrm(word);
        return "mov $m, ${word ? r16[reg] : r8[reg]}";
      }(),
    0x8a || 0x8b => () {
        final m = modrm(word);
        return "mov ${word ? r16[reg] : r8[reg]}, $m";
      }(),
    0x8c => () {
        final m = modrm(true);
        return "mov $m, ${sreg[reg & 3]}";
      }(),
    0x8d => () {
        final m = modrm(true);
        return "lea ${r16[reg]}, $m";
      }(),
    0x8e => () {
        final m = modrm(true);
        return "mov ${sreg[reg & 3]}, $m";
      }(),
    0x8f => "pop ${modrm(true)}",
    0x90 => "nop",
    >= 0x91 && <= 0x97 => "xchg ax, ${r16[op & 7]}",
    0x98 => "cbw",
    0x99 => "cwd",
    0x9a => () {
        final off = u16();
        return "call ${u16().x4}:${off.x4}";
      }(),
    0x9b => "wait",
    0x9c => "pushf",
    0x9d => "popf",
    0x9e => "sahf",
    0x9f => "lahf",
    0xa0 => "mov al, byte $seg[${u16().x4}]",
    0xa1 => "mov ax, word $seg[${u16().x4}]",
    0xa2 => "mov byte $seg[${u16().x4}], al",
    0xa3 => "mov word $seg[${u16().x4}], ax",
    0xa4 => "${prefix}movsb",
    0xa5 => "${prefix}movsw",
    0xa6 => "${prefix}cmpsb",
    0xa7 => "${prefix}cmpsw",
    0xa8 => "test al, ${u8().x2}",
    0xa9 => "test ax, ${u16().x4}",
    0xaa => "${prefix}stosb",
    0xab => "${prefix}stosw",
    0xac => "${prefix}lodsb",
    0xad => "${prefix}lodsw",
    0xae => "${prefix}scasb",
    0xaf => "${prefix}scasw",
    >= 0xb0 && <= 0xb7 => "mov ${r8[op & 7]}, ${u8().x2}",
    >= 0xb8 && <= 0xbf => "mov ${r16[op & 7]}, ${u16().x4}",
    0xc0 || 0xc1 || >= 0xd0 && <= 0xd3 => () {
        final m = modrm(word);
        final count = op < 0xd0
            ? u8().x2
            : op < 0xd2
                ? "1"
                : "cl";
        return "${shifts[reg]} $m, $count";
      }(),
    0xc2 => "ret ${u16().x4}",
    0xc3 => "ret",
    0xc4 || 0xc5 => () {
        final m = modrm(true);
        return "${op == 0xc4 ? "les" : "lds"} ${r16[reg]}, $m";
      }(),
    0xc6 => () {
        final m = modrm(false);
        return "mov $m, ${u8().x2}";
      }(),
    0xc7 => () {
        final m = modrm(true);
        return "mov $m, ${u16().x4}";
      }(),
    0xc8 => () {
        final size = u16();
        return "enter ${size.x4}, ${u8().x2}";
      }(),
    0xc9 => "leave",
    0xca => "retf ${u16().x4}",
    0xcb => "retf",
    0xcc => "int 3",
    0xcd => "int ${u8().x2}",
    0xce => "into",
    0xcf => "iret",
    0xd4 => "aam ${u8().x2}",
    0xd5 => "aad ${u8().x2}",
    0xd6 => "salc",
    0xd7 => "xlat",
    >= 0xd8 && <= 0xdf => "esc ${modrm(true)}",
    0xe0 => "loopnz ${rel(s8())}",
    0xe1 => "loopz ${rel(s8())}",
    0xe2 => "loop ${rel(s8())}",
    0xe3 => "jcxz ${rel(s8())}",
    0xe4 => "in al, ${u8().x2}",
    0xe5 => "in ax, ${u8().x2}",
    0xe6 => "out ${u8().x2}, al",
    0xe7 => "out ${u8().x2}, ax",
    0xe8 => "call ${rel(u16().rel16)}",
    0xe9 => "jmp ${rel(u16().rel16)}",
    0xea => () {
        final off = u16();
        return "jmp ${u16().x4}:${off.x4}";
      }(),
    0xeb => "jmp ${rel(s8())}",
    0xec => "in al, dx",
    0xed => "in ax, dx",
    0xee => "out dx, al",
    0xef => "out dx, ax",
    0xf4 => "hlt",
    0xf5 => "cmc",
    0xf6 || 0xf7 => () {
        final m = modrm(word);
        const names = [
          "test",
          "test",
          "not",
          "neg",
          "mul",
          "imul",
          "div",
          "idiv"
        ];
        if (reg < 2) return "test $m, ${word ? u16().x4 : u8().x2}";
        return "${names[reg]} $m";
      }(),
    0xf8 => "clc",
    0xf9 => "stc",
    0xfa => "cli",
    0xfb => "sti",
    0xfc => "cld",
    0xfd => "std",
    0xfe => () {
        final m = modrm(false);
        return "${reg == 0 ? "inc" : reg == 1 ? "dec" : "???"} $m";
      }(),
    0xff => () {
        final m = modrm(true);
        const names = [
          "inc",
          "dec",
          "call",
          "call far",
          "jmp",
          "jmp far",
          "push",
          "???"
        ];
        return "${names[reg]} $m";
      }(),
    _ => "db ${op.x2}",
  };
  return (text, pos);
}

/// call and return semantics of the instruction for tracing
TraceFlow traceV30Flow(int Function(int offset) read, int ip, int length) {
  var pos = 0;
  var op = read(pos);
  while ((op == 0x26 || op == 0x2e || op == 0x36 || op == 0x3e) && pos < 4) {
    op = read(++pos);
  }
  final next = (ip + length).mask16;
  return switch (op) {
    0xe8 || 0x9a => TraceFlow.call(next),
    0xff when (read(pos + 1) >> 3 & 7) == 2 || (read(pos + 1) >> 3 & 7) == 3 =>
      TraceFlow.call(next),
    0xc2 || 0xc3 || 0xca || 0xcb => const TraceFlow.returned(),
    0xcf => const TraceFlow.interruptReturn(),
    0xcc || 0xcd => TraceFlow.exception(next),
    _ => TraceFlow.none,
  };
}
