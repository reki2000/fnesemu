import 'package:fnesemu/util/int.dart';

import '../../../util/debug.dart';

class DisasmR3000 {
  static const cop0 = [
    "index",
    "random",
    "entrylo0",
    "entrylo1",
    "context",
    "pagemask",
    "wired",
    "reserved",
    "badvaddr",
    "count",
    "entryhi",
    "compare",
    "sr",
    "cause",
    "epc",
    "prid",
    "config",
    "lladdr",
    "watchlo",
    "watchhi",
    "xcontext",
    "", "", "", "", "", "", "", "", "", "", "", //
  ];

  static const regs = [
    "zero", "at", //
    "v0", "v1", //
    "a0", "a1", "a2", "a3", //
    "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", //
    "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", //
    "t8", "t9", //
    "k0", "k1", //
    "gp", "sp", "fp", "ra", //
  ];

  static String _unknown(int inst32) {
    final op = inst32 >> 26 & 0x3f;
    final rs = inst32 >> 21 & 0x1f;
    final rt = inst32 >> 16 & 0x1f;
    final rd = inst32 >> 11 & 0x1f;
    return "unknown opcode:${inst32.hex32} op:${op.hex8} rs:${rs.hex8} rt:${rt.hex8} rd:${rd.hex8}";
  }

  static _reg(int no) => no == 0 ? "0" : "r$no";

  static String disasm(int inst32, {int pc = 0}) {
    final op = inst32 >> 26 & 0x3f;
    final rs = inst32 >> 21 & 0x1f;
    final rt = inst32 >> 16 & 0x1f;
    final rd = inst32 >> 11 & 0x1f;

    final rs_ = _reg(rs);
    final rt_ = _reg(rt);
    final rd_ = _reg(rd);

    final shamt = inst32 >> 6 & 0x1f;
    final funct = inst32 & 0x3f;

    final im16_ = inst32.rel16.toRadixString(16);
    final rel16_ = (pc + (inst32.rel16 << 2)).mask32.hex32;
    final rel26_ = (pc + (inst32.rel26 << 2)).mask32.hex32;

    // print(
    //     "op:${op.hex8} rs:${rs.hex8} rt:${rt.hex8} rd:${rd.hex8} shamt:${shamt.hex8} funct:${funct.hex8} im16:$im16_ im26:$im26_");

    return switch (op) {
      0x00 => switch (funct) {
          0x00 => "sll $rd_, $rt_, $shamt",
          0x02 => "srl $rd_, $rt_, $shamt",
          0x03 => "sra $rd_, $rt_, $shamt",
          0x04 => "sllv $rd_, $rt_, $rs_",
          0x06 => "srlv $rd_, $rt_, $rs_",
          0x07 => "srav $rd_, $rt_, $rs_",
          0x08 => "jr $rs_",
          0x09 => "jalr $rd_, $rs_",
          0x0c => "syscall",
          0x0d => "break",
          0x10 => "mfhi $rd_",
          0x11 => "mthi $rs_",
          0x12 => "mflo $rd_",
          0x13 => "mtlo $rs_",
          0x18 => "mult $rs_, $rt_",
          0x19 => "multu $rs_, $rt_",
          0x1a => "div $rs_, $rt_",
          0x1b => "divu $rs_, $rt_",
          0x20 => "add $rd_, $rs_, $rt_",
          0x21 => "addu $rd_, $rs_, $rt_",
          0x22 => "sub $rd_, $rs_, $rt_",
          0x23 => "subu $rd_, $rs_, $rt_",
          0x24 => "and $rd_, $rs_, $rt_",
          0x25 => "or $rd_, $rs_, $rt_",
          0x26 => "xor $rd_, $rs_, $rt_",
          0x27 => "nor $rd_, $rs_, $rt_",
          0x2a => "slt $rd_, $rs_, $rt_",
          0x2b => "sltu $rd_, $rs_, $rt_",
          _ => _unknown(inst32),
        },
      0x01 => switch (rt & 0xf1) {
          0x00 => "bltz $rs_, $rel16_",
          0x01 => "bgez $rs_, $rel16_",
          0x10 => "bltzal $rs_, $rel16_",
          0x11 => "bgezal $rs_, $rel16_",
          _ => _unknown(inst32),
        },
      0x02 => "j $rel26_",
      0x03 => "jal $rel26_",
      0x04 => "beq $rs_, $rt_, $rel16_",
      0x05 => "bne $rs_, $rt_, $rel16_",
      0x06 => "blez $rs_, $rel16_",
      0x07 => "bgtz $rs_, $rel16_",
      0x08 => "addi $rt_, $rs_, $im16_",
      0x09 => "addiu $rt_, $rs_, $im16_",
      0x0a => "slti $rt_, $rs_, $im16_",
      0x0b => "sltiu $rt_, $rs_, $im16_",
      0x0c => "andi $rt_, $rs_, $im16_",
      0x0d => "ori $rt_, $rs_, $im16_",
      0x0e => "xori $rt_, $rs_, $im16_",
      0x0f => "lui $rt_, $im16_",
      0x10 => switch (rs) {
          0x00 => "mfc0 $rt_, cop0_r$rd:${cop0[rd]}",
          0x04 => "mtc0 $rt_, cop0_r$rd:${cop0[rd]}",
          >= 0x10 && <= 0x1f => switch (funct) {
              0x10 => "rfe",
              _ => _unknown(inst32),
            },
          _ => _unknown(inst32),
        },
      0x12 => switch (rs) {
          0x00 => "mfc2 $rt_, cop2_r$rd",
          0x01 => "cfc2 $rt_, cop2_r$rd",
          0x04 => "mtc2 $rt_, cop2_r$rd",
          0x05 => "ctc2 $rt_, cop2_r$rd",
          >= 0x10 && <= 0x1f => switch (funct) {
              0x01 => "rtps",
              0x06 => "nclip",
              0x0c => "op",
              0x10 => "dpcs",
              0x11 => "intpl",
              0x12 => "mvmva",
              0x13 => "ncds",
              0x14 => "cdp",
              0x16 => "ncdt",
              0x1b => "nccs",
              0x1c => "cc",
              0x1e => "ncs",
              0x20 => "nct",
              0x28 => "sqr",
              0x29 => "dcpl",
              0x2a => "dpct",
              0x2d => "avsz3",
              0x2e => "avsz4",
              0x30 => "rtpt",
              0x3d => "gpf",
              0x3e => "gpl",
              0x3f => "ncct",
              _ => _unknown(inst32),
            },
          _ => _unknown(inst32),
        },
      0x20 => "lb $rt_, $im16_($rs_)",
      0x21 => "lh $rt_, $im16_($rs_)",
      0x22 => "lwl $rt_, $im16_($rs_)",
      0x23 => "lw $rt_, $im16_($rs_)",
      0x24 => "lbu $rt_, $im16_($rs_)",
      0x25 => "lhu $rt_, $im16_($rs_)",
      0x26 => "lwr $rt_, $im16_($rs_)",
      0x28 => "sb $rt_, $im16_($rs_)",
      0x29 => "sh $rt_, $im16_($rs_)",
      0x2a => "swl $rt_, $im16_($rs_)",
      0x2b => "sw $rt_, $im16_($rs_)",
      0x2e => "swr $rt_, $im16_($rs_)",
      0x32 => "lwc2 $rt_, $im16_($rs_)",
      0x3a => "swc2 $rt_, $im16_($rs_)",
      // => "syscall",
      // => "break",
      _ => _unknown(inst32),
    };
  }
}

main(List<String> args) {
  for (final arg in args) {
    final inst32 = int.parse(arg, radix: 16);
    debugLog("${inst32.hex32} ${DisasmR3000.disasm(inst32)}");
  }
}
