part of 'r3000.dart';

/// The GTE, attached to the PS embedding of the shared core as its COP2 device.
class Cop2 implements R3000Cop2 {
  final R3000 cpu;

  Cop2(this.cpu);

  /// the registers as MFC2 and CFC2 read them: the data registers, then the
  /// control registers. The fields below are views of them, so that a JIT
  /// that holds them can move most registers by itself.
  Uint32List _regs = Uint32List(64);

  /// Moves the registers to [words], which hold them from then on.
  void useRegisters(Uint32List words) {
    words.setAll(0, _regs);
    _regs = words;
  }

  /// Copies the registers out of the words [useRegisters] gave.
  void releaseRegisters() => _regs = Uint32List.fromList(_regs);

  /// How a block may write register r of MTC2 (r) and CTC2 (32 + r) to the
  /// registers by itself: 0 as it is, 1 sign extended from 16 bits and 2
  /// zero extended from 16 bits. -1 leaves the write to [writeReg] or
  /// [writeCtrl], for the registers whose write has an effect.
  static const writeForms = <int>[
    0, 1, 0, 1, 0, 1, 0, 2, 1, 1, 1, 1, 0, 0, 0, -1, //
    2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, -1, -1, -1, -1, //
    0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, //
    0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, -1,
  ];

  /// The register that a block reads for register r of MFC2 (r) and CFC2
  /// (32 + r), or -1 when [readReg] derives the value.
  static int heldRegister(int reg) => switch (reg) {
        15 => 14,
        28 || 29 => -1,
        _ => reg,
      };

  // rotation matrix, signed 4.12 bit x 2

  int get rt11 => _regs[32].rel16;
  set rt11(int value) => _regs[32] = (_regs[32] & 0xffff0000) | value.mask16;
  int get rt12 => _regs[32].shr16.rel16;
  set rt12(int value) => _regs[32] = _regs[32].mask16 | value.mask16.shl16;
  int get rt13 => _regs[33].rel16;
  set rt13(int value) => _regs[33] = (_regs[33] & 0xffff0000) | value.mask16;
  int get rt21 => _regs[33].shr16.rel16;
  set rt21(int value) => _regs[33] = _regs[33].mask16 | value.mask16.shl16;
  int get rt22 => _regs[34].rel16;
  set rt22(int value) => _regs[34] = (_regs[34] & 0xffff0000) | value.mask16;
  int get rt23 => _regs[34].shr16.rel16;
  set rt23(int value) => _regs[34] = _regs[34].mask16 | value.mask16.shl16;
  int get rt31 => _regs[35].rel16;
  set rt31(int value) => _regs[35] = (_regs[35] & 0xffff0000) | value.mask16;
  int get rt32 => _regs[35].shr16.rel16;
  set rt32(int value) => _regs[35] = _regs[35].mask16 | value.mask16.shl16;
  int get rt33 => _regs[36].rel32;
  set rt33(int value) => _regs[36] = value.rel16.mask32;
  Matrix get rt => (rt11, rt12, rt13, rt21, rt22, rt23, rt31, rt32, rt33);

  // transformation matrix, signed 32 bit

  int get trx => _regs[37].rel32;
  set trx(int value) => _regs[37] = value.mask32;
  int get try_ => _regs[38].rel32;
  set try_(int value) => _regs[38] = value.mask32;
  int get trz => _regs[39].rel32;
  set trz(int value) => _regs[39] = value.mask32;
  Vector get tr => (trx, try_, trz);

  // light matrix, signed 4.12 bit x 2

  int get l11 => _regs[40].rel16;
  set l11(int value) => _regs[40] = (_regs[40] & 0xffff0000) | value.mask16;
  int get l12 => _regs[40].shr16.rel16;
  set l12(int value) => _regs[40] = _regs[40].mask16 | value.mask16.shl16;
  int get l13 => _regs[41].rel16;
  set l13(int value) => _regs[41] = (_regs[41] & 0xffff0000) | value.mask16;
  int get l21 => _regs[41].shr16.rel16;
  set l21(int value) => _regs[41] = _regs[41].mask16 | value.mask16.shl16;
  int get l22 => _regs[42].rel16;
  set l22(int value) => _regs[42] = (_regs[42] & 0xffff0000) | value.mask16;
  int get l23 => _regs[42].shr16.rel16;
  set l23(int value) => _regs[42] = _regs[42].mask16 | value.mask16.shl16;
  int get l31 => _regs[43].rel16;
  set l31(int value) => _regs[43] = (_regs[43] & 0xffff0000) | value.mask16;
  int get l32 => _regs[43].shr16.rel16;
  set l32(int value) => _regs[43] = _regs[43].mask16 | value.mask16.shl16;
  int get l33 => _regs[44].rel32;
  set l33(int value) => _regs[44] = value.rel16.mask32;
  Matrix get l => (l11, l12, l13, l21, l22, l23, l31, l32, l33);

  // light color matrix, signed 4.12 bit x 2

  int get lc11 => _regs[48].rel16;
  set lc11(int value) => _regs[48] = (_regs[48] & 0xffff0000) | value.mask16;
  int get lc12 => _regs[48].shr16.rel16;
  set lc12(int value) => _regs[48] = _regs[48].mask16 | value.mask16.shl16;
  int get lc13 => _regs[49].rel16;
  set lc13(int value) => _regs[49] = (_regs[49] & 0xffff0000) | value.mask16;
  int get lc21 => _regs[49].shr16.rel16;
  set lc21(int value) => _regs[49] = _regs[49].mask16 | value.mask16.shl16;
  int get lc22 => _regs[50].rel16;
  set lc22(int value) => _regs[50] = (_regs[50] & 0xffff0000) | value.mask16;
  int get lc23 => _regs[50].shr16.rel16;
  set lc23(int value) => _regs[50] = _regs[50].mask16 | value.mask16.shl16;
  int get lc31 => _regs[51].rel16;
  set lc31(int value) => _regs[51] = (_regs[51] & 0xffff0000) | value.mask16;
  int get lc32 => _regs[51].shr16.rel16;
  set lc32(int value) => _regs[51] = _regs[51].mask16 | value.mask16.shl16;
  int get lc33 => _regs[52].rel32;
  set lc33(int value) => _regs[52] = value.rel16.mask32;
  Matrix get lc => (lc11, lc12, lc13, lc21, lc22, lc23, lc31, lc32, lc33);

  // background color, signed 20.12 bit

  int get rbk => _regs[45].rel32;
  set rbk(int value) => _regs[45] = value.mask32;
  int get gbk => _regs[46].rel32;
  set gbk(int value) => _regs[46] = value.mask32;
  int get bbk => _regs[47].rel32;
  set bbk(int value) => _regs[47] = value.mask32;
  Vector get bk => (rbk, gbk, bbk);

  // far color,  signed 28.4 bit

  int get rfc => _regs[53].rel32;
  set rfc(int value) => _regs[53] = value.mask32;
  int get gfc => _regs[54].rel32;
  set gfc(int value) => _regs[54] = value.mask32;
  int get bfc => _regs[55].rel32;
  set bfc(int value) => _regs[55] = value.mask32;
  Vector get fc => (rfc, gfc, bfc);

  // screen offset and distanct

  int get ofx => _regs[56].rel32;
  set ofx(int value) => _regs[56] = value.mask32;
  int get ofy => _regs[57].rel32;
  set ofy(int value) => _regs[57] = value.mask32;
  int get h => _regs[58].mask16;
  set h(int value) => _regs[58] = value.rel16.mask32;
  int get dqa => _regs[59].rel32;
  set dqa(int value) => _regs[59] = value.rel16.mask32;
  int get dqb => _regs[60].rel32;
  set dqb(int value) => _regs[60] = value.mask32;

  // average z

  int get zsf3 => _regs[61].rel32;
  set zsf3(int value) => _regs[61] = value.rel16.mask32;
  int get zsf4 => _regs[62].rel32;
  set zsf4(int value) => _regs[62] = value.rel16.mask32;
  int get otz => _regs[7];
  set otz(int value) => _regs[7] = value.mask16;

  // screen xy registers, signed 16 bit x 2

  int get sx0 => _regs[12].rel16;
  set sx0(int value) => _regs[12] = (_regs[12] & 0xffff0000) | value.mask16;
  int get sy0 => _regs[12].shr16.rel16;
  set sy0(int value) => _regs[12] = _regs[12].mask16 | value.mask16.shl16;
  int get sx1 => _regs[13].rel16;
  set sx1(int value) => _regs[13] = (_regs[13] & 0xffff0000) | value.mask16;
  int get sy1 => _regs[13].shr16.rel16;
  set sy1(int value) => _regs[13] = _regs[13].mask16 | value.mask16.shl16;

  int get _sx2 => _regs[14].rel16;
  set _sx2(int value) => _regs[14] = (_regs[14] & 0xffff0000) | value.mask16;
  int get sx2 => _sx2;
  set sx2(int value) => _sx2 = clipOverflow(value, -0x400, 0x3ff, 14);

  int get _sy2 => _regs[14].shr16.rel16;
  set _sy2(int value) => _regs[14] = _regs[14].mask16 | value.mask16.shl16;
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

  int get sz0 => _regs[16];
  set sz0(int value) => _regs[16] = value.mask16;
  int get sz1 => _regs[17];
  set sz1(int value) => _regs[17] = value.mask16;
  int get sz2 => _regs[18];
  set sz2(int value) => _regs[18] = value.mask16;
  int get _sz3 => _regs[19];
  set _sz3(int value) => _regs[19] = value.mask16;
  int get sz3 => _sz3;
  set sz3(int value) {
    sz0 = sz1;
    sz1 = sz2;
    sz2 = sz3;
    _sz3 = clipOverflow(value, 0x0000, 0xffff, 18);
  }

  // vector registers, signed 16 bit or signed 4.12 bit x 2

  int get vx0 => _regs[0].rel16;
  set vx0(int value) => _regs[0] = (_regs[0] & 0xffff0000) | value.mask16;
  int get vy0 => _regs[0].shr16.rel16;
  set vy0(int value) => _regs[0] = _regs[0].mask16 | value.mask16.shl16;
  int get vz0 => _regs[1].rel32;
  set vz0(int value) => _regs[1] = value.rel16.mask32;
  Vector get v0 => (vx0, vy0, vz0);

  int get vx1 => _regs[2].rel16;
  set vx1(int value) => _regs[2] = (_regs[2] & 0xffff0000) | value.mask16;
  int get vy1 => _regs[2].shr16.rel16;
  set vy1(int value) => _regs[2] = _regs[2].mask16 | value.mask16.shl16;
  int get vz1 => _regs[3].rel32;
  set vz1(int value) => _regs[3] = value.rel16.mask32;
  Vector get v1 => (vx1, vy1, vz1);

  int get vx2 => _regs[4].rel16;
  set vx2(int value) => _regs[4] = (_regs[4] & 0xffff0000) | value.mask16;
  int get vy2 => _regs[4].shr16.rel16;
  set vy2(int value) => _regs[4] = _regs[4].mask16 | value.mask16.shl16;
  int get vz2 => _regs[5].rel32;
  set vz2(int value) => _regs[5] = value.rel16.mask32;
  Vector get v2 => (vx2, vy2, vz2);

  // 16bit intermediate registers, signed 4.12 bit

  int get _ir0 => _regs[8].rel32;
  set _ir0(int value) => _regs[8] = value.rel16.mask32;
  int get ir0 => _ir0;
  set ir0(int value) => _ir0 = clipOverflow(value, 0x0000, 0x1000, 12);

  int get _ir1 => _regs[9].rel32;
  set _ir1(int value) => _regs[9] = value.rel16.mask32;
  int get ir1 => _ir1;
  set ir1(int value) =>
      _ir1 = clipOverflow(value.rel32, lm ? 0x0000 : -0x8000, 0x7fff, 24);
  set ir1lm0(int value) =>
      _ir1 = clipOverflow(value.rel32, -0x8000, 0x7fff, 24);

  int get _ir2 => _regs[10].rel32;
  set _ir2(int value) => _regs[10] = value.rel16.mask32;
  int get ir2 => _ir2;
  set ir2(int value) =>
      _ir2 = clipOverflow(value.rel32, lm ? 0x0000 : -0x8000, 0x7fff, 23);
  set ir2lm0(int value) =>
      _ir2 = clipOverflow(value.rel32, -0x8000, 0x7fff, 23);

  int get _ir3 => _regs[11].rel32;
  set _ir3(int value) => _regs[11] = value.rel16.mask32;
  int get ir3 => _ir3;
  set ir3(int value) =>
      _ir3 = clipOverflow(value.rel32, lm ? 0x0000 : -0x8000, 0x7fff, 22);
  set ir3lm0(int value) =>
      _ir3 = clipOverflow(value.rel32, -0x8000, 0x7fff, 22);
  Vector get ir => (ir1, ir2, ir3);

  // 32bit intermediate registers, signed 32 bit

  int get _mac0 => _regs[24].rel32;
  set _mac0(int value) => _regs[24] = value.mask32;
  int get mac0 => _mac0;
  set mac0(int value) =>
      _mac0 = checkOverflow(value, -0x80000000, 0x7fffffff, 16, 15).rel32;

  int get _mac1 => _regs[25].rel32;
  set _mac1(int value) => _regs[25] = value.mask32;
  int get mac1 => _mac1;
  set mac1(int value) => _mac1 =
      (checkOverflow(value, -0x80000000000, 0x7ffffffffff, 30, 27) >> shift)
          .rel32;

  int get _mac2 => _regs[26].rel32;
  set _mac2(int value) => _regs[26] = value.mask32;
  int get mac2 => _mac2;
  set mac2(int value) => _mac2 =
      (checkOverflow(value, -0x80000000000, 0x7ffffffffff, 29, 26) >> shift)
          .rel32;

  int get _mac3 => _regs[27].rel32;
  set _mac3(int value) => _regs[27] = value.mask32;
  int get mac3 => _mac3;
  set mac3(int value) => _mac3 =
      (checkOverflow(value, -0x80000000000, 0x7ffffffffff, 28, 25) >> shift)
          .rel32;

  // color registers,  unsigned 8 bit x 4

  int get rgbc => _regs[6];
  set rgbc(int value) => _regs[6] = value.mask32;
  int get r => rgbc.mask8;
  int get g => rgbc.shr8.mask8;
  int get b => rgbc.shr16.mask8;
  int get code => rgbc.shr24.mask8;
  Vector get rgb => (r.shl4, g.shl4, b.shl4);

  setRgb(int r, int g, int b, int code) {
    r = clipOverflow(r, 0, 0xff, 21);
    g = clipOverflow(g, 0, 0xff, 20);
    b = clipOverflow(b, 0, 0xff, 19);
    return code.mask8.shl24 | b.shl16 | g.shl8 | r;
  }

  int get rgb0 => _regs[20];
  set rgb0(int value) => _regs[20] = value.mask32;
  int get rgb1 => _regs[21];
  set rgb1(int value) => _regs[21] = value.mask32;
  int get rgb2 => _regs[22];
  set rgb2(int value) => _regs[22] = value.mask32;
  setRgb2(int r, int g, int b, int code) => rgb2 = setRgb(r, g, b, code);

  // color conversion registers, unsigned 5 bit x 3
  set irgb(int value) {
    _ir1 = value.shl7 & 0xf80;
    _ir2 = value.shl2 & 0xf80;
    _ir3 = value.shr3 & 0xf80;
  }

  int get orgb =>
      ir1.shr7.clip(0, 0x1f) |
      ir2.shr7.clip(0, 0x1f).shl5 |
      ir3.shr7.clip(0, 0x1f).shl10;

  int get lzcs => _regs[30];
  set lzcs(int value) => _regs[30] = value.mask32;
  int get lzcr => _regs[31];
  set lzcr(int value) => _regs[31] = value.mask32;

  int get res1 => _regs[23];
  set res1(int value) => _regs[23] = value.mask32;

  int flag = 0;

  /// Puts [flag] into the registers, as CFC2 reads it: bit 31 is set when
  /// any of the error bits 13-18 and 23-30 is.
  void _syncFlag() => _regs[63] =
      (flag & 0x7f87e000 != 0 ? 0x80000000 : 0) | (flag & 0x7ffff000);

  setFlag(int bit) {
    flag |= (1 << bit);
  }

  // no: 1,2,3
  int co44(int no, int value) {
    // overflow/underflow bits: 30/27, 29/26, 28/25
    return checkOverflow(value, -0x80000000000, 0x7ffffffffff, 31 - no, 28 - no)
        .rel44;
  }

  int checkOverflow(
      int value, int min, int max, int bitOverflow, int bitUnderflow) {
    // _log.debugc(() =>
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
    // _log.debugc(() => "gte: h:$h, sz:$sz, z:$z, d:$d");
    final n = h << z;
    final u = unrTable[(d - 0x7fc0) >>> 7] + 0x101;
    d = (0x2000080 - (d * u)) >>> 8;
    d = (0x0000080 + (d * u)) >>> 8;
    return (((n * d) + 0x8000).shr16).min(0x1ffff);
  }

  int cmd = 0;
  bool lm = false;
  bool sf = false;
  int shift = 0;

  reset() {}

  // The register fields are saved directly, not through the register write path, whose clipping and FIFO pushes would change them.
  void saveState(StateWriter w) {
    w.section('ps-gte');
    w.ints([
      rt11, rt12, rt13, rt21, rt22, rt23, rt31, rt32, rt33, //
      trx, try_, trz, //
      l11, l12, l13, l21, l22, l23, l31, l32, l33, //
      lc11, lc12, lc13, lc21, lc22, lc23, lc31, lc32, lc33, //
      rbk, gbk, bbk, rfc, gfc, bfc, //
      ofx, ofy, h, dqa, dqb, zsf3, zsf4, otz, //
      sx0, sy0, sx1, sy1, _sx2, _sy2, //
      sz0, sz1, sz2, _sz3, //
      vx0, vy0, vz0, vx1, vy1, vz1, vx2, vy2, vz2, //
      _ir0, _ir1, _ir2, _ir3, //
      _mac0, _mac1, _mac2, _mac3, //
      rgbc, rgb0, rgb1, rgb2, res1, //
      lzcs, lzcr, flag, cmd, shift,
    ]);
    w.boolean(lm);
    w.boolean(sf);
  }

  void loadState(StateReader s) {
    s.section('ps-gte');
    final v = s.ints();
    if (v.length != 81) throw const StateMismatch('ps gte state layout');
    var i = 0;
    rt11 = v[i++];
    rt12 = v[i++];
    rt13 = v[i++];
    rt21 = v[i++];
    rt22 = v[i++];
    rt23 = v[i++];
    rt31 = v[i++];
    rt32 = v[i++];
    rt33 = v[i++];
    trx = v[i++];
    try_ = v[i++];
    trz = v[i++];
    l11 = v[i++];
    l12 = v[i++];
    l13 = v[i++];
    l21 = v[i++];
    l22 = v[i++];
    l23 = v[i++];
    l31 = v[i++];
    l32 = v[i++];
    l33 = v[i++];
    lc11 = v[i++];
    lc12 = v[i++];
    lc13 = v[i++];
    lc21 = v[i++];
    lc22 = v[i++];
    lc23 = v[i++];
    lc31 = v[i++];
    lc32 = v[i++];
    lc33 = v[i++];
    rbk = v[i++];
    gbk = v[i++];
    bbk = v[i++];
    rfc = v[i++];
    gfc = v[i++];
    bfc = v[i++];
    ofx = v[i++];
    ofy = v[i++];
    h = v[i++];
    dqa = v[i++];
    dqb = v[i++];
    zsf3 = v[i++];
    zsf4 = v[i++];
    otz = v[i++];
    sx0 = v[i++];
    sy0 = v[i++];
    sx1 = v[i++];
    sy1 = v[i++];
    _sx2 = v[i++];
    _sy2 = v[i++];
    sz0 = v[i++];
    sz1 = v[i++];
    sz2 = v[i++];
    _sz3 = v[i++];
    vx0 = v[i++];
    vy0 = v[i++];
    vz0 = v[i++];
    vx1 = v[i++];
    vy1 = v[i++];
    vz1 = v[i++];
    vx2 = v[i++];
    vy2 = v[i++];
    vz2 = v[i++];
    _ir0 = v[i++];
    _ir1 = v[i++];
    _ir2 = v[i++];
    _ir3 = v[i++];
    _mac0 = v[i++];
    _mac1 = v[i++];
    _mac2 = v[i++];
    _mac3 = v[i++];
    rgbc = v[i++];
    rgb0 = v[i++];
    rgb1 = v[i++];
    rgb2 = v[i++];
    res1 = v[i++];
    lzcs = v[i++];
    lzcr = v[i++];
    flag = v[i++];
    _syncFlag();
    cmd = v[i++];
    shift = v[i++];
    lm = s.boolean();
    sf = s.boolean();
  }

  @override
  int readCtrl(int reg) => _read(reg.mask5 | 0x20);
  @override
  void writeCtrl(int reg, int value) => _write(reg.mask5 | 0x20, value);
  @override
  int readReg(int reg) => _read(reg.mask5);
  @override
  void writeReg(int reg, int value) => _write(reg.mask5, value);

  int _read(int reg) => switch (reg) {
        15 => _regs[14],
        28 || 29 => orgb.mask32,
        _ => _regs[reg],
      };

  void _write(int reg, int value) {
    // _log.debugc(() => "cop2 [$reg] <= ${value.x8}");

    switch (reg) {
      case 0:
        vx0 = value.rel16;
        vy0 = value.rel32.shr16;
      case 1:
        vz0 = value.rel16;
      case 2:
        vx1 = value.rel16;
        vy1 = value.rel32.shr16;
      case 3:
        vz1 = value.rel16;
      case 4:
        vx2 = value.rel16;
        vy2 = value.rel32.shr16;
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
        sy0 = value.rel32.shr16;
      case 13:
        sx1 = value.rel16;
        sy1 = value.rel32.shr16;
      case 14:
        _sx2 = value.rel16;
        _sy2 = value.rel32.shr16;
      case 15:
        sx0 = sx1;
        sy0 = sy1;
        sx1 = sx2;
        sy1 = sy2;
        _sx2 = value.rel16;
        _sy2 = value.rel32.shr16;
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
        rt12 = value.rel32.shr16;
      case 33:
        rt13 = value.rel16;
        rt21 = value.rel32.shr16;
      case 34:
        rt22 = value.rel16;
        rt23 = value.rel32.shr16;
      case 35:
        rt31 = value.rel16;
        rt32 = value.rel32.shr16;
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
        l12 = value.rel32.shr16;
      case 41:
        l13 = value.rel16;
        l21 = value.rel32.shr16;
      case 42:
        l22 = value.rel16;
        l23 = value.rel32.shr16;
      case 43:
        l31 = value.rel16;
        l32 = value.rel32.shr16;
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
        lc12 = value.rel32.shr16;
      case 49:
        lc13 = value.rel16;
        lc21 = value.rel32.shr16;
      case 50:
        lc22 = value.rel16;
        lc23 = value.rel32.shr16;
      case 51:
        lc31 = value.rel16;
        lc32 = value.rel32.shr16;
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
        _syncFlag();
      default:
        throw ("cpu: unimplimited cop2 write $reg  ${value.x8}");
    }
  }

  @override
  void execCmd(int inst32) {
    cmd = inst32;
    lm = inst32.bit10;
    sf = inst32.bit19;
    shift = sf ? 12 : 0;
    flag = 0;

    // _log.debugc(() => "cop2: ${[
    //   "EX_00", "RTPS", "EX_02", "EX_03", "EX_04", "EX_05", "NCLIP", "EX_07", //
    //   "EX_08", "EX_09", "EX_0A", "EX_0B", "OP", "EX_0D", "EX_0E", "EX_0F", //
    //   "DPCS", "INTPL", "MVMVA", "NCDS", "CDP", "EX_15", "NCDT", "EX_17", //
    //   "EX_18", "EX_19", "EX_1A", "NCCS", "CC", "EX_1D", "NCS", "EX_1F", //
    //   "NCT", "EX_21", "EX_22", "EX_23", "EX_24", "EX_25", "EX_26", "EX_27", //
    //   "SQR", "DCPL", "DPCT", "EX_2B", "EX_2C", "AVSZ3", "AVSZ4", "EX_2F", //
    //   "RTPT", "EX_31", "EX_32", "EX_33", "EX_34", "EX_35", "EX_36", "EX_37", //
    //   "EX_38", "EX_39", "EX_3A", "EX_3B", "EX_3C", "GPF", "GPL", "NCCT" //
    // ][inst32 & 0x3f]} ${(inst32 & 0x3f).x2}");

    _execCmd(inst32);
    _syncFlag();
  }

  void _execCmd(int inst32) {
    return switch (inst32.mask6) {
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
      _ => null, // undefined gte commands: ignored
    };
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
