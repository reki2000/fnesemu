import 'package:fnesemu/util/int.dart';

import 'package:fnesemu/util/debug.dart';

const showAddress = true;

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

  static const cop2 = [
    "vx0vy0", "vz0", "vx1vy1", "vz1", "vx2vy2", "vz2", //
    "rgbc", "otz", "ir0", "ir1", "ir2", "ir3", //
    "sx0xy0", "sx1xy1", "sx2xy2", "sxpsyp", "sz0", "sz1", "sz2", "sz3", //
    "rgb0", "rgb1", "rgb2", "-", "mac0", "mac1", "mac2", "mac3", "irgb", "orgb",
    "data32", "lzc", //
    "r11r12", "r13r21", "r22r23", "r31r32", "r33", "trx", "try", "trz", //
    "l11l12", "l13l21", "l22l23", "l31l32", "l33", "rbk", "gbk", "bbk", //
    "lc11lc12", "lc13lc21", "lc22lc23", "lc31lc32", "lc33", "rfc", "gfc",
    "bfc", //
    "ofx", "ofy", "h", "dqa", "dqb", "zsf3", "zsf4", "flag" //
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

  static const ioAddr = {
    0x1f801040: "JOY_DATA",
    0x1f801044: "JOY_STAT",
    0x1f801048: "JOY_MODE",
    0x1f80104a: "JOY_CTRL",
    0x1f80104e: "JOY_BAUD",
    0x1f801070: "I_STAT",
    0x1f801074: "I_MASK",
    0x1f801080: "D0_MADR",
    0x1f801084: "D0_BCR",
    0x1f801088: "D0_CHCR",
    0x1f801090: "D1_MADR",
    0x1f801094: "D1_BCR",
    0x1f801098: "D1_CHCR",
    0x1f8010a0: "D2_MADR",
    0x1f8010a4: "D2_BCR",
    0x1f8010a8: "D2_CHCR",
    0x1f8010b0: "D3_MADR",
    0x1f8010b4: "D3_BCR",
    0x1f8010b8: "D3_CHCR",
    0x1f8010c0: "D4_MADR",
    0x1f8010c4: "D4_BCR",
    0x1f8010c8: "D4_CHCR",
    0x1f8010d0: "D5_MADR",
    0x1f8010d4: "D5_BCR",
    0x1f8010d8: "D5_CHCR",
    0x1f8010e0: "D6_MADR",
    0x1f8010e4: "D6_BCR",
    0x1f8010e8: "D6_CHCR",
    0x1f8010f0: "DPCR",
    0x1f8010f4: "DICR",
    0x1f801810: "GPU_DATA",
    0x1f801814: "GPU_STAT",
    0x1f801820: "MDEC_DATA",
    0x1f801824: "MDEC_STAT",
    0x1f801100: "T0_CNT",
    0x1f801104: "T0_MODE",
    0x1f801108: "T0_TGT",
    0x1f801110: "T1_CNT",
    0x1f801114: "T1_MODE",
    0x1f801118: "T1_TGT",
    0x1f801120: "T2_CNT",
    0x1f801124: "T2_MODE",
    0x1f801128: "T2_TGT",
    0x1f801800: "CD_ADR",
    0x1f801801: "CD_RSLT",
    0x1f801802: "CD_DAT",
    0x1f801803: "CD_HINT",
  };

  static String _ioAddrName(int addr) => ioAddr[addr] ?? addr.x8;

  static String _unknown(int inst32) {
    final op = inst32.shr26 & 0x3f;
    final rs = inst32.shr21 & 0x1f;
    final rt = inst32.shr16 & 0x1f;
    final rd = inst32.shr11 & 0x1f;
    return "unknown opcode:${inst32.x8} op:${op.x2} rs:${rs.x2} rt:${rt.x2} rd:${rd.x2}";
  }

  static _reg(int no) => no == 0 ? "0" : "r$no";

  static String disasm(int inst32, {int pc = 0, List<int> regs = const []}) {
    final op = inst32.shr26 & 0x3f;
    final rs = inst32.shr21 & 0x1f;
    final rt = inst32.shr16 & 0x1f;
    final rd = inst32.shr11 & 0x1f;

    final rs_ = _reg(rs);
    final rt_ = _reg(rt);
    final rd_ = _reg(rd);

    final shamt = inst32.shr6 & 0x1f;
    final funct = inst32 & 0x3f;

    final im16_ = inst32.mask16.x4;
    final rel16_ = inst32.rel16.toRadixString(16);
    final pcRel16_ = (pc.inc4 + inst32.rel16.shl2).mask32.x8;
    final pc26_ = (pc.inc4 & 0xf0000000 | inst32.mask26.shl2).x8;

    final addr_ = regs.isNotEmpty && showAddress
        ? ";${_ioAddrName(regs[rs] + inst32.rel16)}"
        : "";

    // print(
    //     "op:${op.x2} rs:${rs.x2} rt:${rt.x2} rd:${rd.x2} shamt:${shamt.x2} funct:${funct.x2} im16:$im16_ im26:$im26_");

    return switch (op) {
      0x00 => switch (funct) {
          0x00 => inst32 == 0 ? "nop" : "sll $rd_, $rt_, $shamt",
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
          0x00 => "bltz $rs_, $pcRel16_",
          0x01 => "bgez $rs_, $pcRel16_",
          0x10 => "bltzal $rs_, $pcRel16_",
          0x11 => "bgezal $rs_, $pcRel16_",
          _ => _unknown(inst32),
        },
      0x02 => "j $pc26_",
      0x03 => "jal $pc26_",
      0x04 => "beq $rs_, $rt_, $pcRel16_",
      0x05 => "bne $rs_, $rt_, $pcRel16_",
      0x06 => "blez $rs_, $pcRel16_",
      0x07 => "bgtz $rs_, $pcRel16_",
      0x08 => "addi $rt_, $rs_, $im16_",
      0x09 => "addiu $rt_, $rs_, $im16_",
      0x0a => "slti $rt_, $rs_, $im16_",
      0x0b => "sltiu $rt_, $rs_, $im16_",
      0x0c => "andi $rt_, $rs_, $im16_",
      0x0d => "ori $rt_, $rs_, $im16_",
      0x0e => "xori $rt_, $rs_, $im16_",
      0x0f => "lui $rt_, $im16_",
      0x10 => switch (rs) {
          0x00 => "mfc0 $rt_, cop0.$rd:${cop0[rd]}",
          0x04 => "mtc0 $rt_, cop0.$rd:${cop0[rd]}",
          >= 0x10 && <= 0x1f => switch (funct) {
              0x10 => "rfe",
              _ => _unknown(inst32),
            },
          _ => _unknown(inst32),
        },
      0x12 => switch (rs) {
          0x00 => "mfc2 $rt_, cop2.$rd:${cop2[rd]}",
          0x02 => "cfc2 $rt_, cop2.$rd:${cop2[rd]}",
          0x04 => "mtc2 $rt_, cop2.$rd:${cop2[rd]}",
          0x06 => "ctc2 $rt_, cop2.$rd:${cop2[rd]}",
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
      0x20 => "lb $rt_, $rel16_($rs_)$addr_",
      0x21 => "lh $rt_, $rel16_($rs_)$addr_",
      0x22 => "lwl $rt_, $rel16_($rs_)$addr_",
      0x23 => "lw $rt_, $rel16_($rs_)$addr_",
      0x24 => "lbu $rt_, $rel16_($rs_)$addr_",
      0x25 => "lhu $rt_, $rel16_($rs_)$addr_",
      0x26 => "lwr $rt_, $rel16_($rs_)$addr_",
      0x28 => "sb $rt_, $rel16_($rs_)$addr_",
      0x29 => "sh $rt_, $rel16_($rs_)$addr_",
      0x2a => "swl $rt_, $rel16_($rs_)$addr_",
      0x2b => "sw $rt_, $rel16_($rs_)$addr_",
      0x2e => "swr $rt_, $rel16_($rs_)$addr_",
      0x32 => "lwc2 cop2.$rt:${cop2[rt]}, $rel16_($rs_)$addr_",
      0x3a => "swc2 cop2.$rt:${cop2[rt]}, $rel16_($rs_)$addr_",
      // => "syscall",
      // => "break",
      _ => _unknown(inst32),
    };
  }
}

main(List<String> args) {
  for (final arg in args) {
    final inst32 = int.parse(arg, radix: 16);
    debugLog("${inst32.x8} ${DisasmR3000.disasm(inst32)}");
  }
}
