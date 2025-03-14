part of 'r3000.dart';

extension Alu on R3000 {
  int lwl(int addr, int org) {
    final value = read32(addr & 0xfffffffc);
    return switch (addr & 3) {
      0 => value,
      1 => value.mask24 << 8 | org.mask8,
      2 => value.mask16 << 16 | org.mask16,
      _ => value.mask8 << 24 | org.mask24,
    };
  }

  int lwr(int addr, int org) {
    final value = read32(addr & 0xfffffffc);
    return switch (addr & 3) {
      0 => value >> 24 | org & 0xffffff00,
      1 => value >> 16 | org & 0xffff0000,
      2 => value >> 8 | org & 0xff000000,
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
    final result = (a + b).mask32;
    // overflow occurs when the same sign results the opposite sign.
    if ((~(a ^ b) & (result ^ a)).bit31) {
      exception(R3000.exceptionOverflow);
      return;
    }

    immediate(rd, result.mask32);
  }

  void sub(RegNo rd, int a, int b) {
    final result = (a - b).mask32;
    // overflow occurs when the opposite sign results the opposite sign.
    if (((a ^ b) & (result ^ a)).bit31) {
      exception(R3000.exceptionOverflow);
      return;
    }

    immediate(rd, result.mask32);
  }

  void mult(int a, int b) {
    // correct 32-bit overflow behavior despite Dart's Javascript float precision
    // (a32 * b32) = (a_low16 * b32) + ((a_high16 * b32) << 16)
    b = b.rel32;
    int low = a.mask16 * b;
    int high = (a.rel32 >> 16) * b;
    low += high.mask16 << 16;
    lo = low.mask32;
    hi = ((low >> 32) + (high >> 16)).mask32;
  }

  void multu(int a, int b) {
    // correct 32-bit overflow behavior despite Dart's Javascript float precision
    // (a32 * b32) = (a_low16 * b32) + ((a_high16 * b32) << 16)
    b = b.mask32;
    int low = a.mask16 * b; // 48bit
    int high = (a.mask32 >>> 16) * b; // 48bit
    low += high.mask16 << 16;
    lo = low.mask32;
    hi = ((low >>> 32) + (high >>> 16)).mask32;
  }

  void div(int a, int b) {
    a = a.mask32;
    b = b.mask32;

    if (b == 0) {
      lo = a.bit31 ? 1 : -1.mask32;
      hi = a;
      return;
    }

    if (a == 0x80000000 && b == 0xffffffff) {
      lo = 0x80000000;
      hi = 0;
      return;
    }

    lo = a.rel32 ~/ b.rel32;
    hi = (a - (lo * b).mask32).mask32;
    // debugLog("div a=${a.hex32} b=${b.hex32} hi=${hi.hex32} lo=${lo.hex32}");
  }

  void divu(int a, int b) {
    a = a.mask32;
    b = b.mask32;

    if (b == 0) {
      lo = 0xffffffff;
      hi = a;
      return;
    }

    lo = a ~/ b;
    hi = (a - (lo * b).mask32).mask32;
  }
}
