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
}
