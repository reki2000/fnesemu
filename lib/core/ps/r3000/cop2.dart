part of 'r3000.dart';

class Cop2 {
  final R3000 cpu;

  Cop2(this.cpu);

  // rotation matrix, signed 4.12 bit x 2

  int rt11 = 0;
  int rt12 = 0;
  int rt13 = 0;
  int rt21 = 0;
  int rt22 = 0;
  int rt23 = 0;
  int rt31 = 0;
  int rt32 = 0;
  int rt33 = 0;
  Matrix get rt => (rt11, rt12, rt13, rt21, rt22, rt23, rt31, rt32, rt33);

  // transformation matrix, signed 32 bit

  int trx = 0;
  int try_ = 0;
  int trz = 0;
  Vector get tr => (trx, try_, trz);

  // light matrix, signed 4.12 bit x 2

  int l11 = 0;
  int l12 = 0;
  int l13 = 0;
  int l21 = 0;
  int l22 = 0;
  int l23 = 0;
  int l31 = 0;
  int l32 = 0;
  int l33 = 0;
  Matrix get l => (l11, l12, l13, l21, l22, l23, l31, l32, l33);

  // light color matrix, signed 4.12 bit x 2

  int lc11 = 0;
  int lc12 = 0;
  int lc13 = 0;
  int lc21 = 0;
  int lc22 = 0;
  int lc23 = 0;
  int lc31 = 0;
  int lc32 = 0;
  int lc33 = 0;
  Matrix get lc => (lc11, lc12, lc13, lc21, lc22, lc23, lc31, lc32, lc33);

  // background color, signed 20.12 bit

  int rbk = 0;
  int gbk = 0;
  int bbk = 0;
  Vector get bk => (rbk, gbk, bbk);

  // far color,  signed 28.4 bit

  int rfc = 0;
  int gfc = 0;
  int bfc = 0;
  Vector get fc => (rfc, gfc, bfc);

  // screen offset and distanct

  int ofx = 0; // signed 16.16 bit
  int ofy = 0; // signed 16.16 bit
  int h = 0; // unsigned 16 bit
  int dqa = 0; // signed 8.8 bit
  int dqb = 0; // signed 8.24 bit

  // average z

  int zsf3 = 0; // signed 4.12 bit
  int zsf4 = 0; // signed 4.12 bit
  int otz = 0;

  // screen xy registers, signed 16 bit x 2

  int sx0 = 0;
  int sy0 = 0;
  int sx1 = 0;
  int sy1 = 0;

  int _sx2 = 0;
  int get sx2 => _sx2;
  set sx2(int value) => _sx2 = clipOverflow(value, -0x400, 0x3ff, 14);

  int _sy2 = 0;
  int get sy2 => _sy2;
  set sy2(int value) => _sy2 = clipOverflow(value, -0x400, 0x3ff, 13);

  set sxp(int value) {
    sx0 = sx1;
    sx1 = sx2;
    sx2 = value;
  }

  set syp(int value) {
    sy0 = sy1;
    sy1 = sy2;
    sy2 = value;
  }

  // screen z registers, unsigned 16 bit

  int sz0 = 0;
  int sz1 = 0;
  int sz2 = 0;
  int _sz3 = 0;
  int get sz3 => _sz3;
  set sz3(int value) {
    sz0 = sz1;
    sz1 = sz2;
    sz2 = sz3;
    _sz3 = clipOverflow(value, 0x0000, 0xffff, 18);
  }

  // vector registers, signed 16 bit or signed 4.12 bit x 2

  int vx0 = 0;
  int vy0 = 0;
  int vz0 = 0;
  Vector get v0 => (vx0, vy0, vz0);

  int vx1 = 0;
  int vy1 = 0;
  int vz1 = 0;
  Vector get v1 => (vx1, vy1, vz1);

  int vx2 = 0;
  int vy2 = 0;
  int vz2 = 0;
  Vector get v2 => (vx2, vy2, vz2);

  // 16bit intermediate registers, signed 4.12 bit

  int _ir0 = 0;
  int get ir0 => _ir0;
  set ir0(int value) => _ir0 = clipOverflow(value, 0x0000, 0x1000, 12);

  int _ir1 = 0;
  int get ir1 => _ir1;
  set ir1(int value) =>
      _ir1 = clipOverflow(value.rel32, lm ? 0x0000 : -0x8000, 0x7fff, 24);
  set ir1lm0(int value) =>
      _ir1 = clipOverflow(value.rel32, -0x8000, 0x7fff, 24);

  int _ir2 = 0;
  int get ir2 => _ir2;
  set ir2(int value) =>
      _ir2 = clipOverflow(value.rel32, lm ? 0x0000 : -0x8000, 0x7fff, 23);
  set ir2lm0(int value) =>
      _ir2 = clipOverflow(value.rel32, -0x8000, 0x7fff, 23);

  int _ir3 = 0;
  int get ir3 => _ir3;
  set ir3(int value) =>
      _ir3 = clipOverflow(value.rel32, lm ? 0x0000 : -0x8000, 0x7fff, 22);
  set ir3lm0(int value) =>
      _ir3 = clipOverflow(value.rel32, -0x8000, 0x7fff, 22);
  Vector get ir => (ir1, ir2, ir3);

  // 32bit intermediate registers, signed 32 bit

  int _mac0 = 0;
  int get mac0 => _mac0;
  set mac0(int value) =>
      _mac0 = checkOverflow(value, -0x80000000, 0x7fffffff, 16, 15).rel32;

  int _mac1 = 0;
  int get mac1 => _mac1;
  set mac1(int value) => _mac1 =
      (checkOverflow(value, -0x80000000000, 0x7ffffffffff, 30, 27) >> shift)
          .rel32;

  int _mac2 = 0;
  int get mac2 => _mac2;
  set mac2(int value) => _mac2 =
      (checkOverflow(value, -0x80000000000, 0x7ffffffffff, 29, 26) >> shift)
          .rel32;

  int _mac3 = 0;
  int get mac3 => _mac3;
  set mac3(int value) => _mac3 =
      (checkOverflow(value, -0x80000000000, 0x7ffffffffff, 28, 25) >> shift)
          .rel32;

  // color registers,  unsigned 8 bit x 4

  int rgbc = 0;
  int get r => rgbc & 0xff;
  int get g => rgbc >> 8 & 0xff;
  int get b => rgbc >> 16 & 0xff;
  int get code => rgbc >> 24 & 0xff;
  Vector get rgb => (r << 4, g << 4, b << 4);

  setRgb(int r, int g, int b, int code) {
    r = clipOverflow(r, 0, 0xff, 21);
    g = clipOverflow(g, 0, 0xff, 20);
    b = clipOverflow(b, 0, 0xff, 19);
    return code.mask8 << 24 | b << 16 | g << 8 | r;
  }

  int rgb0 = 0;
  int rgb1 = 0;
  int rgb2 = 0;
  setRgb2(int r, int g, int b, int code) => rgb2 = setRgb(r, g, b, code);

  // color conversion registers, unsigned 5 bit x 3
  set irgb(int value) {
    _ir1 = value << 7 & 0xf80;
    _ir2 = value << 2 & 0xf80;
    _ir3 = value >> 3 & 0xf80;
  }

  int get orgb =>
      (ir1 >> 7).clip(0, 0x1f) |
      (ir2 >> 7).clip(0, 0x1f) << 5 |
      (ir3 >> 7).clip(0, 0x1f) << 10;

  int lzcs = 0; // signed 32 bit
  int lzcr = 0; // unsigned 6 bit

  int res1 = 0; // u8 x 4

  int flag = 0;
  setFlag(int bit) {
    flag |= (1 << bit);
  }

  // no: 1,2,3
  int co44(int no, int value) {
    final (bitOVerflow, bitUnderflow) = [(30, 27), (29, 26), (28, 25)][no - 1];
    return checkOverflow(
            value, -0x80000000000, 0x7ffffffffff, bitOVerflow, bitUnderflow)
        .rel44;
  }

  int checkOverflow(
      int value, int min, int max, int bitOverflow, int bitUnderflow) {
    // debugLog(
    //     "gte: checkOverflow v:${value.toRadixString(16)} min:${min.toRadixString(16)} max:${max.toRadixString(16)} $bitOverflow, $bitUnderflow");
    if (value > max) {
      setFlag(bitOverflow);
    } else if (value < min) {
      setFlag(bitUnderflow);
    }
    return value;
  }

  int clipAndSetFlag2(
      int val, int min, int max, int underflowBit, int overflowBit) {
    if (val < min) {
      setFlag(underflowBit);
      return min;
    } else if (val > max) {
      setFlag(overflowBit);
      return max;
    }
    return val;
  }

  int clipOverflow(int val, int min, int max, int bit) =>
      clipAndSetFlag2(val, min, max, bit, bit);

  final unrTable = List.generate(
      0x100, (i) => ((0x40000 ~/ (i + 0x100) + 1) ~/ 2 - 0x101).max(0),
      growable: true)
    ..add(0);

  // https://psx-spx.consoledev.net/geometrytransformationenginegte/#gte-division-inaccuracy
  int divUnr(int h, int sz) {
    if (sz * 2 <= h) {
      setFlag(17);
      return 0x1ffff;
    }
    int z = 0;
    int d = sz;
    while (z < 16 && !d.bit15) {
      z++;
      d <<= 1;
    }
    // debugLog("gte: h:$h, sz:$sz, z:$z, d:$d");
    final n = h << z;
    final u = unrTable[(d - 0x7fc0) >>> 7] + 0x101;
    d = (0x2000080 - (d * u)) >>> 8;
    d = (0x0000080 + (d * u)) >>> 8;
    return (((n * d) + 0x8000) >> 16).min(0x1ffff);
  }

  int cmd = 0;
  bool lm = false;
  bool sf = false;
  int shift = 0;

  reset() {}

  _s16x2toU32(int l, int h) => l.mask16 | h.mask16 << 16;

  int readCtrl(int reg) => _read(reg & 0x1f | 0x20);
  void writeCtrl(int reg, int value) => _write(reg & 0x1f | 0x20, value);
  int readReg(int reg) => _read(reg & 0x1f);
  void writeReg(int reg, int value) => _write(reg & 0x1f, value);

  int _read(int reg) => switch (reg) {
        0 => _s16x2toU32(vx0, vy0),
        1 => vz0.rel16.mask32,
        2 => _s16x2toU32(vx1, vy1),
        3 => vz1.rel16.mask32,
        4 => _s16x2toU32(vx2, vy2),
        5 => vz2.rel16.mask32,
        6 => rgbc.mask32,
        7 => otz.mask16,
        8 => ir0.mask32,
        9 => ir1.mask32,
        10 => ir2.mask32,
        11 => ir3.mask32,
        12 => _s16x2toU32(sx0, sy0),
        13 => _s16x2toU32(sx1, sy1),
        14 || 15 => _s16x2toU32(sx2, sy2),
        16 => sz0.mask32,
        17 => sz1.mask32,
        18 => sz2.mask32,
        19 => sz3.mask32,
        20 => rgb0.mask32,
        21 => rgb1.mask32,
        22 => rgb2.mask32,
        23 => res1.mask32,
        24 => mac0.mask32,
        25 => mac1.mask32,
        26 => mac2.mask32,
        27 => mac3.mask32,
        28 || 29 => orgb.mask32,
        30 => lzcs.mask32,
        31 => lzcr.mask32,
        32 => _s16x2toU32(rt11, rt12),
        33 => _s16x2toU32(rt13, rt21),
        34 => _s16x2toU32(rt22, rt23),
        35 => _s16x2toU32(rt31, rt32),
        36 => rt33.rel16.mask32,
        37 => trx.mask32,
        38 => try_.mask32,
        39 => trz.mask32,
        40 => _s16x2toU32(l11, l12),
        41 => _s16x2toU32(l13, l21),
        42 => _s16x2toU32(l22, l23),
        43 => _s16x2toU32(l31, l32),
        44 => l33.rel16.mask32,
        45 => rbk.mask32,
        46 => gbk.mask32,
        47 => bbk.mask32,
        48 => _s16x2toU32(lc11, lc12),
        49 => _s16x2toU32(lc13, lc21),
        50 => _s16x2toU32(lc22, lc23),
        51 => _s16x2toU32(lc31, lc32),
        52 => lc33.rel16.mask32,
        53 => rfc.mask32,
        54 => gfc.mask32,
        55 => bfc.mask32,
        56 => ofx.mask32,
        57 => ofy.mask32,
        58 => h.rel16.mask32, // sign extension bug
        59 => dqa.rel16.mask32,
        60 => dqb.mask32,
        61 => zsf3.mask32,
        62 => zsf4.mask32,
        63 => [0, 13, 14, 15, 16, 17, 18, 23, 24, 25, 26, 27, 28, 29, 30]
                .reduce((a, i) => a | flag << (31 - i) & 0x80000000) |
            (flag & 0x7ffff000),
        _ => throw ("cpu: unimplimited cop2 read $reg"),
      };

  void _write(int reg, int value) {
    // debugLog("cpu: cop2 [$reg] <= ${value.x8}");

    switch (reg) {
      case 0:
        vx0 = value.rel16;
        vy0 = value.rel32 >> 16;
      case 1:
        vz0 = value.rel16;
      case 2:
        vx1 = value.rel16;
        vy1 = value.rel32 >> 16;
      case 3:
        vz1 = value.rel16;
      case 4:
        vx2 = value.rel16;
        vy2 = value.rel32 >> 16;
      case 5:
        vz2 = value.rel16;
      case 6:
        rgbc = value.mask32;
      case 7:
        otz = value.mask32;

      case 8:
        _ir0 = value.rel16;
      case 9:
        _ir1 = value.rel16;
      case 10:
        _ir2 = value.rel16;
      case 11:
        _ir3 = value.rel16;

      case 12:
        sx0 = value.rel16;
        sy0 = value.rel32 >> 16;
      case 13:
        sx1 = value.rel16;
        sy1 = value.rel32 >> 16;
      case 14:
        _sx2 = value.rel16;
        _sy2 = value.rel32 >> 16;
      case 15:
        sx0 = sx1;
        sy0 = sy1;
        sx1 = sx2;
        sy1 = sy2;
        _sx2 = value.rel16;
        _sy2 = value.rel32 >> 16;
      case 16:
        sz0 = value.mask16;
      case 17:
        sz1 = value.mask16;
      case 18:
        sz2 = value.mask16;
      case 19:
        _sz3 = value.mask16;

      case 20:
        rgb0 = value.mask32;
      case 21:
        rgb1 = value.mask32;
      case 22:
        rgb2 = value.mask32;

      case 23:
        res1 = value.mask32;

      case 24:
        _mac0 = value.mask32;
      case 25:
        _mac1 = value.mask32;
      case 26:
        _mac2 = value.mask32;
      case 27:
        _mac3 = value.mask32;

      case 28:
        irgb = value;
      case 29: // orgb
        break;

      case 30:
        lzcs = value.mask32;
        lzcr = 1;
        final msb = value.bit31;
        while (lzcr < 32 && msb == value.bit(31 - lzcr)) {
          lzcr++;
        }
      case 31:
        break; // lzcr

      case 32:
        rt11 = value.rel16;
        rt12 = value.rel32 >> 16;
      case 33:
        rt13 = value.rel16;
        rt21 = value.rel32 >> 16;
      case 34:
        rt22 = value.rel16;
        rt23 = value.rel32 >> 16;
      case 35:
        rt31 = value.rel16;
        rt32 = value.rel32 >> 16;
      case 36:
        rt33 = value.rel16;

      case 37:
        trx = value.rel32;
      case 38:
        try_ = value.rel32;
      case 39:
        trz = value.rel32;

      case 40:
        l11 = value.rel16;
        l12 = value.rel32 >> 16;
      case 41:
        l13 = value.rel16;
        l21 = value.rel32 >> 16;
      case 42:
        l22 = value.rel16;
        l23 = value.rel32 >> 16;
      case 43:
        l31 = value.rel16;
        l32 = value.rel32 >> 16;
      case 44:
        l33 = value.rel16;

      case 45:
        rbk = value.rel32;
      case 46:
        gbk = value.rel32;
      case 47:
        bbk = value.rel32;

      case 48:
        lc11 = value.rel16;
        lc12 = value.rel32 >> 16;
      case 49:
        lc13 = value.rel16;
        lc21 = value.rel32 >> 16;
      case 50:
        lc22 = value.rel16;
        lc23 = value.rel32 >> 16;
      case 51:
        lc31 = value.rel16;
        lc32 = value.rel32 >> 16;
      case 52:
        lc33 = value.rel16;

      case 53:
        rfc = value.rel32;
      case 54:
        gfc = value.rel32;
      case 55:
        bfc = value.rel32;

      case 56:
        ofx = value.rel32;
      case 57:
        ofy = value.rel32;
      case 58:
        h = value.mask16;
      case 59:
        dqa = value.rel16;
      case 60:
        dqb = value.rel32;
      case 61:
        zsf3 = value.rel16;
      case 62:
        zsf4 = value.rel16;

      case 63:
        flag = value.mask32;
      default:
        throw ("cpu: unimplimited cop2 write $reg  ${value.x8}");
    }
  }

  void execCmd(int inst32) {
    cmd = inst32;
    lm = inst32.bit10;
    sf = inst32.bit19;
    shift = sf ? 12 : 0;
    flag = 0;

    // debugLog("cop2: ${[
    //   "EX_00", "RTPS", "EX_02", "EX_03", "EX_04", "EX_05", "NCLIP", "EX_07", //
    //   "EX_08", "EX_09", "EX_0A", "EX_0B", "OP", "EX_0D", "EX_0E", "EX_0F", //
    //   "DPCS", "INTPL", "MVMVA", "NCDS", "CDP", "EX_15", "NCDT", "EX_17", //
    //   "EX_18", "EX_19", "EX_1A", "NCCS", "CC", "EX_1D", "NCS", "EX_1F", //
    //   "NCT", "EX_21", "EX_22", "EX_23", "EX_24", "EX_25", "EX_26", "EX_27", //
    //   "SQR", "DCPL", "DPCT", "EX_2B", "EX_2C", "AVSZ3", "AVSZ4", "EX_2F", //
    //   "RTPT", "EX_31", "EX_32", "EX_33", "EX_34", "EX_35", "EX_36", "EX_37", //
    //   "EX_38", "EX_39", "EX_3A", "EX_3B", "EX_3C", "GPF", "GPL", "NCCT" //
    // ][inst32 & 0x3f]} ${(inst32 & 0x3f).x2}");

    return switch (inst32 & 0x3f) {
      0x01 => rtps(vx0, vy0, vz0),
      0x06 => nclip(),
      0x0c => op(),
      0x10 => dpcs(),
      0x11 => intpl(),
      0x12 => mvmva(),
      0x13 => ncds(vx0, vy0, vz0),
      0x14 => cdp(),
      0x16 => ncdt(),
      0x1b => nccs(vx0, vy0, vz0),
      0x1c => cc(),
      0x1e => ncs(vx0, vy0, vz0),
      0x20 => nct(),
      0x28 => sqr(),
      0x29 => dcpl(),
      0x2a => dpct(),
      0x2d => avsz3(),
      0x2e => avsz4(),
      0x30 => rtpt(),
      0x3d => gpf(),
      0x3e => gpl(),
      0x3f => ncct(),
      _ => R3000._unknown(inst32),
    };
  }

  void _unimplemented(String s) {
    debugLog("unimplemented: $s");
  }

  String dump() => """
    cop2: ${cmd.x8} lm:$lm sf:$sf shift:$shift
    v0: $vx0, $vy0, $vz0 v1: $vx1, $vy1, $vz1 v2: $vx2, $vy2, $vz2
    rt: {$rt11, $rt12, $rt13}, {$rt21, $rt22, $rt23}, {$rt31, $rt32, $rt33}
    tr: $trx, $try_, $trz
    l: {$l11, $l12, $l13}, {$l21, $l22, $l23}, {$l31, $l32, $l33}
    lc: {$lc11, $lc12, $lc13}, {$lc21, $lc22, $lc23}, {$lc31, $lc32, $lc33}
    rbk:$rbk gbk:$gbk bbk:$bbk rfc:$rfc gfc:$gfc bfc:$bfc
    rgbc:${rgbc.x8} rgb0:${rgb0.x8} rgb1:${rgb1.x8} rgb2:${rgb2.x8}
    otz:$otz h:$h ofx:$ofx ofy:$ofy  dqa:$dqa dqb:$dqb
    s0: $sx0, $sy0 s1: $sx1, $sy1 s2: $sx2, $sy2 sz: $sz0, $sz1, $sz2, $sz3
    ${dumpMac()}
  """;

  String dumpMac() =>
      "mac0:${mac0.x8} mac1:${mac1.x8} mac2:${mac2.x8} mac3:${mac3.x8} "
      "ir0:${ir0.x8} ir1:${ir1.x8} ir2:${ir2.x8} ir3:${ir3.x8} "
      "flag:${readCtrl(31).x8}";
}
