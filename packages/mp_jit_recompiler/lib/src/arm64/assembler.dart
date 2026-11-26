/// Minimal A64 encoder. X18 is reserved for the host platform.
final class Arm64Label {
  int? at;
  final List<(int, int?)> uses = [];
}

final class Arm64Assembler {
  final words = <int>[];
  int get offset => words.length * 4;
  List<int> get bytes => [
    for (final w in words)
      for (var i = 0; i < 4; i++) (w >>> (i * 8)) & 255,
  ];
  void emit(int word) => words.add(word & 0xffffffff);
  void bind(Arm64Label label) {
    label.at = words.length;
    for (final (at, cc) in label.uses) {
      final delta = words.length - at;
      final bits = cc == null ? 26 : 19;
      if (delta < -(1 << (bits - 1)) || delta >= 1 << (bits - 1)) {
        throw StateError('ARM64 branch out of range');
      }
      words[at] = cc == null
          ? 0x14000000 | (delta & 0x3ffffff)
          : 0x54000000 | ((delta & 0x7ffff) << 5) | cc;
    }
  }

  void branch(Arm64Label label, [int? cc]) {
    if (label.at != null) {
      final delta = label.at! - words.length;
      emit(
        cc == null
            ? 0x14000000 | (delta & 0x3ffffff)
            : 0x54000000 | ((delta & 0x7ffff) << 5) | cc,
      );
    } else {
      label.uses.add((words.length, cc));
      emit(0);
    }
  }

  void constant(int dst, int value, {bool wide = false}) {
    emit((wide ? 0xd2800000 : 0x52800000) | ((value & 0xffff) << 5) | dst);
    for (var i = 1; i < (wide ? 4 : 2); i++) {
      final part = (value >>> (i * 16)) & 0xffff;
      if (part != 0) {
        emit((wide ? 0xf2800000 : 0x72800000) | (i << 21) | (part << 5) | dst);
      }
    }
  }

  void move(int dst, int src, {bool wide = false}) =>
      emit((wide ? 0xaa0003e0 : 0x2a0003e0) | (src << 16) | dst);
  void alu(int opcode, int dst, int left, int right, {bool wide = false}) =>
      emit(
        opcode | (wide ? 0x80000000 : 0) | (right << 16) | (left << 5) | dst,
      );
  void cmp(int left, int right, {bool wide = false}) =>
      alu(0x6b000000, 31, left, right, wide: wide);
  void cset(int dst, int cc) => emit(0x1a9f07e0 | ((cc ^ 1) << 12) | dst);
  void select(int dst, int yes, int no, int cc, {bool wide = false}) => emit(
    (wide ? 0x9a800000 : 0x1a800000) |
        (no << 16) |
        (cc << 12) |
        (yes << 5) |
        dst,
  );
  void immediate(
    int dst,
    int src,
    int amount, {
    bool sub = false,
    bool shifted = false,
  }) => emit(
    (sub ? 0xd1000000 : 0x91000000) |
        (shifted ? 1 << 22 : 0) |
        (amount << 10) |
        (src << 5) |
        dst,
  );
  void memory(bool load, int reg, int base, int offset, {int size = 8}) {
    if (offset < 0) throw ArgumentError.value(offset);
    if (offset % size != 0 || offset ~/ size >= 4096) {
      immediate(17, base, offset >>> 12, shifted: true);
      immediate(17, 17, offset & 4095);
      base = 17;
      offset = 0;
    }
    final code = switch (size) {
      1 => 0x39000000,
      2 => 0x79000000,
      4 => 0xb9000000,
      8 => 0xf9000000,
      _ => throw ArgumentError.value(size),
    };
    emit(
      code |
          (load ? 1 << 22 : 0) |
          ((offset ~/ size) << 10) |
          (base << 5) |
          reg,
    );
  }

  void extend(
    int dst,
    int src,
    int bits, {
    bool signed = false,
    bool wide = false,
  }) => emit(
    (signed ? 0x13000000 : 0x53000000) |
        (wide ? 0x80400000 : 0) |
        ((bits - 1) << 10) |
        (src << 5) |
        dst,
  );
  void reverse(int reg, int size) => emit(
    (size == 8
            ? 0xdac00c00
            : size == 4
            ? 0x5ac00800
            : 0x5ac00400) |
        (reg << 5) |
        reg,
  );
  void jump(int address) {
    constant(16, address, wide: true);
    emit(0xd61f0200);
  }

  void call(int address) {
    constant(16, address, wide: true);
    emit(0xd63f0200);
  }

  void pushPair(int a, int b) => emit(0xa9bf0000 | (b << 10) | (31 << 5) | a);
  void popPair(int a, int b) => emit(0xa8c10000 | (b << 10) | (31 << 5) | a);

  // ---- Advanced SIMD, on whole 128-bit registers ----

  /// LDR or STR of the Q register [q] at [base] + [offset], through X17
  /// for an offset that the scaled form cannot hold
  void vmemory(bool load, int q, int base, int offset) {
    if (offset % 16 != 0 || offset ~/ 16 >= 4096) {
      immediate(17, base, offset >>> 12, shifted: true);
      immediate(17, 17, offset & 4095);
      base = 17;
      offset = 0;
    }
    emit((load ? 0x3dc00000 : 0x3d800000) |
        ((offset ~/ 16) << 10) |
        (base << 5) |
        q);
  }

  /// the 16-byte constants after the code, by their words
  final _pool = <String, int>{};
  final _poolWords = <int>[];
  final _poolUses = <(int, int)>[];

  /// LDR (literal) of the 16-byte constant [w] into the Q register [q]
  void vconstant(int q, List<int> w) {
    final key = w.join(',');
    final at = _pool[key] ??= _poolWords.length ~/ 4;
    if (at * 4 == _poolWords.length) {
      for (final x in w) {
        _poolWords.add(x & 0xffffffff);
      }
    }
    _poolUses.add((words.length, at));
    emit(0x9c000000 | q);
  }

  /// Places the constants of [vconstant], 16-byte aligned, at the end.
  void finishPool() {
    if (_poolWords.isEmpty) return;
    while (words.length % 4 != 0) {
      emit(0xd503201f); // NOP
    }
    final start = words.length;
    words.addAll(_poolWords);
    for (final (at, index) in _poolUses) {
      words[at] |= ((start + 4 * index - at) & 0x7ffff) << 5;
    }
  }

  /// a three-register operation [op] with Rd, Rn and Rm
  void v3(int op, int d, int n, int m) => emit(op | (m << 16) | (n << 5) | d);

  /// a two-register operation [op] with Rd and Rn
  void v2(int op, int d, int n) => emit(op | (n << 5) | d);

  void vmov(int d, int n) {
    if (d != n) v3(V.orr, d, n, n);
  }

  /// SHL, USHR or SRI of the 32-bit lanes by [amount]
  void vshl(int d, int n, int amount) =>
      v2(0x4f005400 | ((32 + amount) << 16), d, n);
  void vushr(int d, int n, int amount) =>
      v2(0x6f000400 | ((64 - amount) << 16), d, n);
  void vsri(int d, int n, int amount) =>
      v2(0x6f004400 | ((64 - amount) << 16), d, n);

  /// USHLL or USHLL2 of the low or the high 32-bit lanes to 64 bits by
  /// [amount]
  void vushll(int d, int n, int amount, {bool high = false}) =>
      v2((high ? 0x6f00a400 : 0x2f00a400) | ((32 + amount) << 16), d, n);

  /// SSHLL or SSHLL2 by 0: the low or high 32-bit lanes sign extended
  void vsxtl(int d, int n, {bool high = false}) =>
      v2(high ? 0x4f20a400 : 0x0f20a400, d, n);

  /// SHLL or SHLL2: the low or high 32-bit lanes shifted to the upper words
  void vshll32(int d, int n, {bool high = false}) =>
      v2(high ? 0x6ea13800 : 0x2ea13800, d, n);

  /// SCVTF or FCVTZS of the 64-bit lanes, with [fraction] fraction bits
  void vscvtf(int d, int n, int fraction) => v2(
    fraction == 0 ? 0x4e61d800 : 0x4f40e400 | ((128 - fraction) << 16),
    d,
    n,
  );
  void vfcvtzs(int d, int n, int fraction) => v2(
    fraction == 0 ? 0x4ee1b800 : 0x4f40fc00 | ((128 - fraction) << 16),
    d,
    n,
  );

  /// SQXTN or SQXTN2 of the 64-bit lanes into the low or high 32-bit lanes
  void vsqxtn(int d, int n, {bool high = false}) =>
      v2(high ? 0x4ea14800 : 0x0ea14800, d, n);

  /// DUP of the 32-bit lane [lane] or the 64-bit lane [lane] of Vn
  void vdupLane(int d, int n, int lane) =>
      v2(0x4e040400 | (lane << 19), d, n);
  void vdupLane64(int d, int n, int lane) =>
      v2(0x4e080400 | (lane << 20), d, n);

  /// DUP of the general register Wn to every 32-bit lane
  void vdupGeneral(int d, int n) => v2(0x4e040c00, d, n);

  /// INS of Wn into the 32-bit lane [lane]
  void vinsGeneral(int d, int lane, int n) =>
      v2(0x4e041c00 | (lane << 19), d, n);

  /// INS of the 64-bit lane [from] of Vn into the 64-bit lane [lane]
  void vins64(int d, int lane, int n, int from) =>
      v2(0x6e080400 | (lane << 20) | (from << 14), d, n);

  /// UMOV of the 32-bit lane [lane] to Wd
  void vumov(int d, int n, int lane) => v2(0x0e043c00 | (lane << 19), d, n);
}

/// Advanced SIMD opcodes on 128-bit registers: 32-bit lanes (4S), 64-bit
/// lanes (2D) or bytes (16B)
abstract final class V {
  // three registers
  static const and = 0x4e201c00, bic = 0x4e601c00, orr = 0x4ea01c00;
  static const eor = 0x6e201c00, bit = 0x6ea01c00;
  static const add4s = 0x4ea08400, sub4s = 0x6ea08400;
  static const cmgt4s = 0x4ea03400, cmhi4s = 0x6ea03400;
  static const cmtst4s = 0x4ea08c00;
  static const fadd2d = 0x4e60d400, fsub2d = 0x4ee0d400, fmul2d = 0x6e60dc00;
  static const uzp1 = 0x4e801800, uzp2 = 0x4e805800;
  static const tbl = 0x4e000000;
  // two registers
  static const cmeq0 = 0x4ea09800, cmlt0 = 0x4ea0a800, neg4s = 0x6ea0b800;
  static const addv4s = 0x4eb1b800;
}
