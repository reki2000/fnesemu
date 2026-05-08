extension IntFormat on int {
  /// formats a number with commas per 3 digits
  String get format3 {
    int column = 0;
    final r = List<String>.empty(growable: true);
    for (int val = abs(); column == 0 || val != 0; val ~/= 10) {
      if (column > 0 && column % 3 == 0) {
        r.add(',');
      }
      column++;

      r.add('0123456789'[val % 10]);
    }

    return "${this < 0 ? "-" : ""}${r.reversed.join()}";
  }

  // format a number with specified bit wide hexadecimals
  String get hex8 => mask8.toRadixString(16).padLeft(2, "0");
  String get hex16 => mask16.toRadixString(16).padLeft(4, "0");
  String get hex24 => mask24.toRadixString(16).padLeft(6, "0");
  String get hex32 => mask32.toRadixString(16).padLeft(8, "0");
  String get hex => toRadixString(16);
  String get x2 => hex8;
  String get x4 => hex16;
  String get x6 => hex24;
  String get x8 => hex32;

  String get decimal2 => toString().padLeft(2, " ");
  String get decimal3 => toString().padLeft(3, " ");
  String get decimal4 => toString().padLeft(4, " ");
  String get decimal2z => toString().padLeft(2, "0");
  String get decimal3z => toString().padLeft(3, "0");
  String get decimal4z => toString().padLeft(4, "0");
}

extension IntBit on int {
  // mask a number with specified bit wide mask
  int get mask1 => this & 0x1;
  int get mask2 => this & 0x3;
  int get mask3 => this & 0x7;
  int get mask4 => this & 0xf;
  int get mask5 => this & 0x1f;
  int get mask6 => this & 0x3f;
  int get mask7 => this & 0x7f;
  int get mask8 => this & 0xff;
  int get mask9 => this & 0x1ff;
  int get mask10 => this & 0x3ff;
  int get mask11 => this & 0x7ff;
  int get mask12 => this & 0xfff;
  int get mask13 => this & 0x1fff;
  int get mask14 => this & 0x3fff;
  int get mask15 => this & 0x7fff;
  @pragma('vm:prefer-inline')
  int get mask16 => this & 0xffff;
  @pragma('vm:prefer-inline')
  int get mask24 => this & 0xffffff;
  int get mask26 => this & 0x3ffffff;
  @pragma('vm:prefer-inline')
  int get mask32 => this & 0xffffffff;
  int get mask44 => this & 0xfffffffffff;

  /// mask a number but zero means the max value (mask + 1)
  @pragma('vm:prefer-inline')
  int maskZeroMax(int mask) => (dec & mask).inc;

  /// mask a number with specified byte size
  @pragma('vm:prefer-inline')
  int mask(int size) => size == 1
      ? mask8
      : size == 2
          ? mask16
          : size == 4
              ? mask32
              : throw ("unreachable");

  /// mask a number with specified byte size, keep the sign bit
  @pragma('vm:prefer-inline')
  int smask(int size) => size == 1
      ? mask8.rel8.mask32
      : size == 2
          ? mask16.rel16.mask32
          : size == 4
              ? mask32
              : throw ("unreachable");

  /// check if the most significant bit is set
  bool msb(int size) => size == 1
      ? bit7
      : size == 2
          ? bit15
          : size == 4
              ? bit31
              : throw ("unreachable");

  /// fast multiply a number by 1, 2, 4
  int scale(int size) => size == 1
      ? this
      : size == 2
          ? this << 1
          : size == 4
              ? this << 2
              : throw ("unreachable");

  /// number of bits of the byte size
  int get bits => this == 1
      ? 8
      : this == 2
          ? 16
          : this == 4
              ? 32
              : throw ("unreachable");

  // shortcut for increment and decrement to reduce blackets
  int get inc => this + 1;
  int get inc2 => this + 2;
  int get inc3 => this + 3;
  int get inc4 => this + 4;
  int get dec => this - 1;
  int get dec2 => this - 2;
  int get dec3 => this - 3;
  int get dec4 => this - 4;

  // sign extend a number with specified bit width
  int get rel4 => (this & 0xf) - ((this & 0x8) << 1);
  int get rel5 => (this & 0x1f) - ((this & 0x10) << 1);
  int get rel6 => (this & 0x3f) - ((this & 0x20) << 1);
  int get rel7 => (this & 0x7f) - ((this & 0x40) << 1);
  @pragma('vm:prefer-inline')
  int get rel8 => (this & 0xff) - ((this & 0x80) << 1);
  int get rel9 => (this & 0x1ff) - ((this & 0x100) << 1);
  int get rel10 => (this & 0x3ff) - ((this & 0x200) << 1);
  int get rel11 => (this & 0x7ff) - ((this & 0x400) << 1);
  int get rel12 => (this & 0xfff) - ((this & 0x800) << 1);
  int get rel13 => (this & 0x1fff) - ((this & 0x1000) << 1);
  int get rel14 => (this & 0x3fff) - ((this & 0x2000) << 1);
  int get rel15 => (this & 0x7fff) - ((this & 0x4000) << 1);
  @pragma('vm:prefer-inline')
  int get rel16 => (this & 0xffff) - ((this & 0x8000) << 1);
  @pragma('vm:prefer-inline')
  int get rel24 => (this & 0xffffff) - ((this & 0x800000) << 1);
  int get rel26 => (this & 0x3ffffff) - ((this & 0x2000000) << 1);
  @pragma('vm:prefer-inline')
  int get rel32 => (this & 0xffffffff) - ((this & 0x80000000) << 1);
  int get rel44 => (this & 0xfffffffffff) - ((this & 0x80000000000) << 1);

  /// sign extend a number with specified byte size
  int rel(int size) => size == 1
      ? rel8
      : size == 2
          ? rel16
          : size == 4
              ? rel32
              : throw ("unreachable");

  /// replace part of the number with mask and new value
  int masked(int mask, int value) => this & ~mask | value & mask;

  /// replace specific bit of the number with new value
  int setBit(int bit, bool value) =>
      value ? this | (1 << bit) : this & ~(1 << bit);

  int setL8(int val) => masked(0xff, val);
  int setH8(int val) => masked(0xff00, val << 8);
  int setL16(int val) => masked(0xffff, val);
  int setH16(int val) => masked(0xffff0000, val << 16);

  /// replace part of the number with specified byte size and new value
  int setL(int val, int size) => size == 1
      ? setL8(val)
      : size == 2
          ? setL16(val)
          : size == 4
              ? val
              : throw ("unreachable");

  /// check if specific bit is set
  @pragma('vm:prefer-inline')
  bool bit(int b) => this & (1 << b) != 0;

  // shortcut for bit check to reduce blackets
  @pragma('vm:prefer-inline')
  bool get bit0 => this & 0x1 != 0;
  bool get bit1 => this & 0x2 != 0;
  bool get bit2 => this & 0x4 != 0;
  bool get bit3 => this & 0x8 != 0;
  bool get bit4 => this & 0x10 != 0;
  bool get bit5 => this & 0x20 != 0;
  bool get bit6 => this & 0x40 != 0;
  bool get bit7 => this & 0x80 != 0;
  bool get bit8 => this & 0x100 != 0;
  bool get bit9 => this & 0x200 != 0;
  bool get bit10 => this & 0x400 != 0;
  bool get bit11 => this & 0x800 != 0;
  bool get bit12 => this & 0x1000 != 0;
  bool get bit13 => this & 0x2000 != 0;
  bool get bit14 => this & 0x4000 != 0;
  bool get bit15 => this & 0x8000 != 0;
  bool get bit16 => this & 0x10000 != 0;
  bool get bit17 => this & 0x20000 != 0;
  bool get bit18 => this & 0x40000 != 0;
  bool get bit19 => this & 0x80000 != 0;
  bool get bit20 => this & 0x100000 != 0;
  bool get bit21 => this & 0x200000 != 0;
  bool get bit22 => this & 0x400000 != 0;
  bool get bit23 => this & 0x800000 != 0;
  bool get bit24 => this & 0x1000000 != 0;
  bool get bit25 => this & 0x2000000 != 0;
  bool get bit26 => this & 0x4000000 != 0;
  bool get bit27 => this & 0x8000000 != 0;
  bool get bit28 => this & 0x10000000 != 0;
  bool get bit29 => this & 0x20000000 != 0;
  bool get bit30 => this & 0x40000000 != 0;
  bool get bit31 => this & 0x80000000 != 0;
  bool get bit43 => this & 0x80000000000 != 0; // '<<' doesnt work over 32 bits

  int get shl1 => this << 1;
  int get shl2 => this << 2;
  int get shl3 => this << 3;
  int get shl4 => this << 4;
  int get shl5 => this << 5;
  int get shl6 => this << 6;
  int get shl7 => this << 7;
  int get shl8 => this << 8;
  int get shl9 => this << 9;
  int get shl10 => this << 10;
  int get shl11 => this << 11;
  int get shl12 => this << 12;
  int get shl13 => this << 13;
  int get shl14 => this << 14;
  int get shl15 => this << 15;
  int get shl16 => this << 16;
  int get shl17 => this << 17;
  int get shl18 => this << 18;
  int get shl19 => this << 19;
  int get shl20 => this << 20;
  int get shl21 => this << 21;
  int get shl22 => this << 22;
  int get shl23 => this << 23;
  int get shl24 => this << 24;
  int get shl25 => this << 25;
  int get shl26 => this << 26;
  int get shl27 => this << 27;
  int get shl28 => this << 28;
  int get shl29 => this << 29;
  int get shl30 => this << 30;
  int get shl31 => this << 31;
  int shl(int n) => this << n;

  int get shr1 => this >> 1;
  int get shr2 => this >> 2;
  int get shr3 => this >> 3;
  int get shr4 => this >> 4;
  int get shr5 => this >> 5;
  int get shr6 => this >> 6;
  int get shr7 => this >> 7;
  int get shr8 => this >> 8;
  int get shr9 => this >> 9;
  int get shr10 => this >> 10;
  int get shr11 => this >> 11;
  int get shr12 => this >> 12;
  int get shr13 => this >> 13;
  int get shr14 => this >> 14;
  int get shr15 => this >> 15;
  int get shr16 => this >> 16;
  int get shr17 => this >> 17;
  int get shr18 => this >> 18;
  int get shr19 => this >> 19;
  int get shr20 => this >> 20;
  int get shr21 => this >> 21;
  int get shr22 => this >> 22;
  int get shr23 => this >> 23;
  int get shr24 => this >> 24;
  int get shr25 => this >> 25;
  int get shr26 => this >> 26;
  int get shr27 => this >> 27;
  int get shr28 => this >> 28;
  int get shr29 => this >> 29;
  int get shr30 => this >> 30;
  int get shr31 => this >> 31;
  int shr(int n) => this >> n;
}

extension IntClip on int {
  // lesser of two numbers
  @pragma('vm:prefer-inline')
  int min(int val) => this < val ? this : val;

  // greater of two numbers
  @pragma('vm:prefer-inline')
  int max(int val) => this > val ? this : val;

  // clip a number between min and max
  @pragma('vm:prefer-inline')
  int clip(int min, int max) => this < min
      ? min
      : this > max
          ? max
          : this;
}
