part of 'r3000.dart';

extension Alu on R3000 {
  int lwl(int addr, int org) {
    final value = read32(addr & 0xfffffffc);
    return switch (addr & 3) {
      0 => value.mask8 << 24 | org.mask24,
      1 => value.mask16 << 16 | org.mask16,
      2 => value.mask24 << 8 | org.mask8,
      _ => value,
    };
  }

  int lwr(int addr, int org) {
    final value = read32(addr & 0xfffffffc);
    return switch (addr & 3) {
      0 => value,
      1 => value >> 8 | org & 0xff000000,
      2 => value >> 16 | org & 0xffff0000,
      _ => value >> 24 | org & 0xffffff00,
    };
  }

  void swl(int addr, int value) {
    final aligned = addr & 0xfffffffc;
    switch (addr & 0x03) {
      case 0:
        write32(aligned, value >> 24 | read32(aligned) & 0xffffff00);
      case 1:
        write32(aligned, value >> 16 | read32(aligned) & 0xffff0000);
      case 2:
        write32(aligned, value >> 8 | read32(aligned) & 0xff000000);
      case 3:
        write32(aligned, value);
    }
  }

  void swr(int addr, int value) {
    final aligned = addr & 0xfffffffc;
    switch (addr & 0x03) {
      case 0:
        write32(aligned, value);
      case 1:
        write32(aligned, value.mask24 << 8 | read32(aligned).mask8);
      case 2:
        write32(aligned, value.mask16 << 16 | read32(aligned).mask16);
      case 3:
        write32(aligned, value.mask8 << 24 | read32(aligned).mask24);
    }
  }

  int sll(int value, int shift) => (value << (shift & 0x1f)).mask32;
  int srl(int value, int shift) => value.mask32 >> (shift & 0x1f);
  int sra(int value, int shift) => (value.rel32 >> (shift & 0x1f)).mask32;

  void add(RegNo rd, int a, int b) {
    final result = (a + b).mask32;
    // overflow occurs when the same sign results the opposite sign.
    if ((~(a ^ b) & (result ^ a)).bit31) {
      exception(Exception.overflow);
      return;
    }

    immediate(rd, result.mask32);
  }

  void sub(RegNo rd, int a, int b) {
    final result = (a - b).mask32;
    // overflow occurs when the opposite sign results the opposite sign.
    if (((a ^ b) & (result ^ a)).bit31) {
      exception(Exception.overflow);
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
    // debugLog("div a=${a.x8} b=${b.x8} hi=${hi.x8} lo=${lo.x8}");
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
