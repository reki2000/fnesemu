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

  String get decimal2 => toString().padLeft(2, " ");
  String get decimal2z => toString().padLeft(2, "0");
}

extension IntBit on int {
  // mask a number with specified bit wide mask
  int get mask4 => this & 0xf;
  int get mask8 => this & 0xff;
  int get mask10 => this & 0x3ff;
  int get mask11 => this & 0x7ff;
  int get mask16 => this & 0xffff;
  int get mask24 => this & 0xffffff;
  int get mask26 => this & 0x3ffffff;
  int get mask32 => this & 0xffffffff;
  int get mask44 => this & 0xfffffffffff;

  /// mask a number but zero means the max value (mask + 1)
  int maskZeroMax(int mask) => (dec & mask).inc;

  /// mask a number with specified byte size
  int mask(int size) => size == 1
      ? mask8
      : size == 2
          ? mask16
          : size == 4
              ? mask32
              : throw ("unreachable");

  /// mask a number with specified byte size, keep the sign bit
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
  int get dec4 => this - 4;

  // sign extend a number with specified bit width
  int get rel4 => bit3 ? mask4 - 0x10 : mask4;
  int get rel8 => bit7 ? mask8 - 0x100 : mask8;
  int get rel10 => bit9 ? mask10 - 0x400 : mask10;
  int get rel11 => bit10 ? mask11 - 0x800 : mask11;
  int get rel16 => bit15 ? mask16 - 0x10000 : mask16;
  int get rel24 => bit23 ? mask24 - 0x1000000 : mask24;
  int get rel26 => bit25 ? mask26 - 0x4000000 : mask26;
  int get rel32 => bit31 ? mask32 - 0x100000000 : mask32;
  int get rel44 => bit43 ? mask44 - 0x100000000000 : mask44;

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
  bool bit(int b) => this & (1 << b) != 0;

  // shortcut for bit check to reduce blackets
  bool get bit0 => bit(0);
  bool get bit1 => bit(1);
  bool get bit2 => bit(2);
  bool get bit3 => bit(3);
  bool get bit4 => bit(4);
  bool get bit5 => bit(5);
  bool get bit6 => bit(6);
  bool get bit7 => bit(7);
  bool get bit8 => bit(8);
  bool get bit9 => bit(9);
  bool get bit10 => bit(10);
  bool get bit11 => bit(11);
  bool get bit12 => bit(12);
  bool get bit13 => bit(13);
  bool get bit14 => bit(14);
  bool get bit15 => bit(15);
  bool get bit16 => bit(16);
  bool get bit17 => bit(17);
  bool get bit18 => bit(18);
  bool get bit19 => bit(19);
  bool get bit20 => bit(20);
  bool get bit21 => bit(21);
  bool get bit22 => bit(22);
  bool get bit23 => bit(23);
  bool get bit24 => bit(24);
  bool get bit25 => bit(25);
  bool get bit26 => bit(26);
  bool get bit27 => bit(27);
  bool get bit28 => bit(28);
  bool get bit29 => bit(29);
  bool get bit30 => bit(30);
  bool get bit31 => bit(31);
  bool get bit43 => this & 0x80000000000 != 0; // '<<' doesnt work over 32 bits
}

extension IntClip on int {
  // lesser of two numbers
  int min(int val) => this < val ? this : val;

  // greater of two numbers
  int max(int val) => this > val ? this : val;

  // clip a number between min and max
  int clip(int min, int max) => this < min
      ? min
      : this > max
          ? max
          : this;
}
