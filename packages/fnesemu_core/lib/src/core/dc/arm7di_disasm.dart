import '../../util/int.dart';

/// ARM7DI integer mnemonics from ARM7DI Data Sheet DDI 0027D, chapter 4.
/// No Thumb, ARMv4 extensions or AICA-external coprocessors are decoded.
String dcArm7diDisasm(int opcode, int address) {
  final op = opcode.mask32;
  String fallback() => '.word 0x${op.x8}';
  const conditions = [
    'eq',
    'ne',
    'cs',
    'cc',
    'mi',
    'pl',
    'vs',
    'vc',
    'hi',
    'ls',
    'ge',
    'lt',
    'gt',
    'le',
    '',
    'nv'
  ];
  final condition = conditions[op >>> 28];
  final rn = (op >> 16) & 15, rd = (op >> 12) & 15, rm = op & 15;
  final setFlags = op & 0x100000 != 0;
  String hex(int value) => '0x${value.mask32.toRadixString(16)}';
  String operand({bool registerOnly = false}) {
    if (!registerOnly && op & 0x2000000 != 0) {
      final rotate = ((op >> 8) & 15) * 2, imm = op & 255;
      return '#${hex(rotate == 0 ? imm : (imm >>> rotate) | (imm << (32 - rotate)))}';
    }
    const shifts = ['lsl', 'lsr', 'asr', 'ror'];
    final type = (op >> 5) & 3, amount = (op >> 7) & 31;
    if (op & 16 != 0) return 'r$rm,${shifts[type]} r${(op >> 8) & 15}';
    if (amount == 0) {
      if (type == 0) return 'r$rm';
      if (type == 3) return 'r$rm,rrx';
    }
    return 'r$rm,${shifts[type]} #${amount == 0 ? 32 : amount}';
  }

  if (op & 0xf000000 == 0xf000000) {
    return 'swi$condition #${hex(op & 0xffffff)}';
  }
  if (op & 0xe000000 == 0xa000000) {
    final offset = ((op & 0xffffff) ^ 0x800000) - 0x800000;
    final target = (address + 8 + offset * 4).mask32;
    return 'b${op & 0x1000000 != 0 ? 'l' : ''}$condition 0x${target.x8}';
  }
  if (op & 0xfbf0fff == 0x10f0000) {
    if (rd == 15) return fallback();
    return 'mrs$condition r$rd,${op & 0x400000 != 0 ? 'spsr' : 'cpsr'}';
  }
  if (op & 0xfbffff0 == 0x129f000 ||
      op & 0xfbffff0 == 0x128f000 ||
      op & 0xfbff000 == 0x328f000) {
    if (op & 0x2000000 == 0 && rm == 15) return fallback();
    final psr = op & 0x400000 != 0 ? 'spsr' : 'cpsr';
    final fields = op & 0x10000 != 0 ? 'all' : 'flg';
    return 'msr$condition ${psr}_$fields,${op & 0x2000000 != 0 ? operand() : 'r$rm'}';
  }
  if (op & 0xfc000f0 == 0x90) {
    final dest = rn, accumulator = rd, rs = (op >> 8) & 15;
    final accumulate = op & 0x200000 != 0;
    if ([dest, rs, rm].contains(15) ||
        (accumulate ? accumulator == 15 : accumulator != 0)) {
      return fallback();
    }
    final name = accumulate ? 'mla' : 'mul';
    return '$name$condition${setFlags ? 's' : ''} r$dest,r$rm,r$rs${accumulate ? ',r$accumulator' : ''}';
  }
  if (op & 0xfb00ff0 == 0x1000090) {
    if ([rn, rd, rm].contains(15)) return fallback();
    return 'swp$condition${op & 0x400000 != 0 ? 'b' : ''} r$rd,r$rm,[r$rn]';
  }
  if (op & 0xe000000 == 0x8000000) {
    final registers = [
      for (var i = 0; i < 16; i++)
        if (op & (1 << i) != 0) 'r$i'
    ];
    if (registers.isEmpty || rn == 15) return fallback();
    final load = op & 0x100000 != 0;
    final mode =
        '${op & 0x800000 != 0 ? 'i' : 'd'}${op & 0x1000000 != 0 ? 'b' : 'a'}';
    return '${load ? 'ldm' : 'stm'}$condition$mode r$rn${op & 0x200000 != 0 ? '!' : ''},{${registers.join(',')}}${op & 0x400000 != 0 ? '^' : ''}';
  }
  if (op & 0xc000000 == 0x4000000) {
    final byRegister = op & 0x2000000 != 0;
    if (byRegister && op & 16 != 0) return fallback();
    final pre = op & 0x1000000 != 0, writeback = op & 0x200000 != 0;
    final sign = op & 0x800000 != 0 ? '' : '-';
    String offset;
    if (byRegister) {
      offset = '$sign${operand(registerOnly: true)}';
    } else {
      offset = '#$sign${hex(op & 0xfff)}';
    }
    final location =
        pre ? '[r$rn,$offset]${writeback ? '!' : ''}' : '[r$rn],$offset';
    return '${op & 0x100000 != 0 ? 'ldr' : 'str'}$condition${op & 0x400000 != 0 ? 'b' : ''}${!pre && writeback ? 't' : ''} r$rd,$location';
  }
  if (op & 0xc000000 == 0) {
    if (op & 0x2000090 == 0x90) return fallback();
    const names = [
      'and',
      'eor',
      'sub',
      'rsb',
      'add',
      'adc',
      'sbc',
      'rsc',
      'tst',
      'teq',
      'cmp',
      'cmn',
      'orr',
      'mov',
      'bic',
      'mvn'
    ];
    final operation = (op >> 21) & 15;
    final test = operation >= 8 && operation <= 11;
    if (test && !setFlags) return fallback();
    final name = '${names[operation]}$condition${!test && setFlags ? 's' : ''}';
    if (test) return '$name r$rn,${operand()}';
    if (operation == 13 || operation == 15) return '$name r$rd,${operand()}';
    return '$name r$rd,r$rn,${operand()}';
  }
  return fallback();
}
