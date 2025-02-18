part of 'r3000.dart';

extension Alu on R3000 {
  int lwl(int addr, int org) {
    final value = read32(addr & ~0x03);
    return switch (addr & 3) {
      0 => value,
      1 => value << 8 | org & 0xff,
      2 => value << 16 | org & 0xffff,
      _ => value << 24 | org & 0xffffff,
    };
  }

  int lwr(int addr, int org) {
    final value = read32(addr & ~0x03);
    return switch (addr & 3) {
      0 => value >>> 24 | org & 0xffffff00,
      1 => value >>> 16 | org & 0xffff0000,
      2 => value >>> 8 | org & 0xff000000,
      _ => value,
    };
  }

  void swl(int value, int addr) {
    final aligned = addr & ~0x03;
    switch (addr & 0x03) {
      case 1:
        write32(aligned, value | read32(aligned) & 0xffffff00);
      case 2:
        write32(aligned, value << 8 | read32(aligned) & 0xffff0000);
      case 3:
        write32(aligned, value << 16 | read32(aligned) & 0xff000000);
    }
  }

  void swr(int value, int addr) {
    final aligned = addr & ~0x03;
    switch (addr & 0x03) {
      case 0:
        write32(aligned, value);
      case 1:
        write32(aligned, value >>> 24 | read32(aligned));
      case 2:
        write32(aligned, value >>> 16 | read32(aligned) & 0xff);
      case 3:
        write32(aligned, value >>> 8 | read32(aligned) & 0xffff);
    }
  }

  int sll(int value, int shift) => (value << (shift & 0x1f)).mask32;
  int srl(int value, int shift) => value.mask32 >> (shift & 0x1f);
  int sra(int value, int shift) => (value.rel32 >> (shift & 0x1f)).mask32;

  void add(RegNo rd, int a, int b) {
    final result = a + b;
    if (result >= (1 << 32)) {
      exception(R3000.exceptionOverflow);
    }

    immediate(rd, result.mask32);
  }

  void sub(RegNo rd, int a, int b) {
    final result = a.rel32 - b.rel32;
    if (result < 0) {
      exception(R3000.exceptionOverflow);
    }

    immediate(rd, result.mask32);
  }

  void mult(int a, int b) {
    int low = a.mask16 * b;
    int high = (a >>> 16) * b;
    lo = (low + high << 16 & 0xffff0000).mask32;
    hi = (high >> 16).mask32;
  }

  void multu(int a, int b) {
    int low = a.mask16 * b;
    int high = (a >>> 16) * b;
    lo = (low + high << 16 & 0xffff0000).mask32;
    hi = (high >> 16).mask32;
  }

  void div(int a, int b) {
    if (b == 0) {
      lo = a >= 0 ? -1 : 1;
      hi = 0xffffffff;
      return;
    }

    if (a == 0x80000000 && b == 0xffffffff) {
      lo = 0x80000000;
      hi = 0;
      return;
    }

    lo = a ~/ b;
    hi = a % b;
  }

  void divu(int a, int b) {
    if (b == 0) {
      lo = a;
      hi = 0xffffffff;
      return;
    }

    lo = a.mask32 ~/ b.mask32;
    hi = a.mask32 % b.mask32;
  }
}
