part of 'r3000.dart';

extension Cop2Command on Cop2 {
  // Perform calculation: T + M * V
  Vector multiplyMatrixT(Matrix m, Vector v, Vector t) => (
        co44(
            1,
            co44(1, co44(1, (t.$1.shl12) + m.$1 * v.$1) + m.$2 * v.$2) +
                m.$3 * v.$3),
        co44(
            2,
            co44(2, co44(2, (t.$2.shl12) + m.$4 * v.$1) + m.$5 * v.$2) +
                m.$6 * v.$3),
        co44(
            3,
            co44(3, co44(3, (t.$3.shl12) + m.$7 * v.$1) + m.$8 * v.$2) +
                m.$9 * v.$3)
      );

  // Perform calculation: M * V
  Vector multiplyMatrix(Matrix m, Vector v) => multiplyMatrixT(m, v, (0, 0, 0));

  void setMacAndIrV(Vector v, {bool lm0 = false}) {
    mac1 = v.$1;
    mac2 = v.$2;
    mac3 = v.$3;
    if (lm0) {
      ir1lm0 = v.$1 >> shift;
      ir2lm0 = v.$2 >> shift;
      ir3lm0 = v.$3 >> shift;
    } else {
      ir1 = v.$1 >> shift;
      ir2 = v.$2 >> shift;
      ir3 = v.$3 >> shift;
    }
  }

  void setMacAndIrVlm0(Vector v) => setMacAndIrV(v, lm0: true);

  void pushColor() {
    rgb0 = rgb1;
    rgb1 = rgb2;
    setRgb2(mac1.shr4, mac2.shr4, mac3.shr4, code); // Preserve original code
  }

  void rtps(int vx, int vy, int vz, {bool setMac0 = true}) {
    final (ssx, ssy, ssz) = multiplyMatrixT(
      rt,
      (vx, vy, vz),
      tr,
    );

    mac1 = ssx;
    ir1 = ssx >> shift;
    mac2 = ssy;
    ir2 = ssy >> shift;
    mac3 = ssz;

    // ir3 saturation ignores lm (as false) but clip depends on lm
    checkOverflow(ssz.shr12, -0x8000, 0x7fff, 22, 22);
    _ir3 = mac3.clip(lm ? 0 : -0x8000, 0x7fff);

    sz3 = ssz.shr12.rel32;

    final hsz1 = divUnr(h.mask16, sz3.mask16);
    // debugLog(
    //     "gte: h:${h.x8} sz3:${sz3.toRadixString(16)} hdz1: ${hsz1.toRadixString(16)} ir1: ${ir1.x8} ofx:${ofx.x8} flag:${flag.x8}");

    final sx = hsz1 * ir1 + ofx;
    mac0 = sx;
    sxp = sx.shr16;

    final sy = hsz1 * ir2 + ofy;
    mac0 = sy;
    syp = sy.shr16;

    if (setMac0) {
      final p = hsz1 * dqa + dqb;
      mac0 = p;
      ir0 = p.shr12;
    }

    // debugLog("gte: rtps ${dump()}");
  }

  void rtpt() {
    rtps(vx0, vy0, vz0, setMac0: false);
    rtps(vx1, vy1, vz1, setMac0: false);
    rtps(vx2, vy2, vz2);
  }

  void nclip() {
    mac0 =
        sx0 * sy1 + sx1 * sy2 + sx2 * sy0 - sx0 * sy2 - sx1 * sy0 - sx2 * sy1;
  }

  void avsz3() {
    final z = zsf3 * (sz1 + sz2 + sz3);
    mac0 = z;
    otz = clipOverflow(z.shr12, 0, 0xffff, 18);
  }

  void avsz4() {
    final z = zsf4 * (sz0 + sz1 + sz2 + sz3);
    mac0 = z;
    otz = clipOverflow(z.shr12, 0, 0xffff, 18);
  }

  void ncds(int vx, int vy, int vz) {
    setMacAndIrV(multiplyMatrix(l, (vx, vy, vz)));
    setMacAndIrV(multiplyMatrixT(lc, ir, bk));

    final ir_ = ir;

    setMacAndIrVlm0(((rfc, gfc, bfc) << 12) - rgb.dot(ir));
    setMacAndIrV(rgb.dot(ir_) + ir * ir0);

    pushColor();
    // debugLog(
    //     "gte: ncds ${vx.x4} ${vy.x4} ${vz.x4} ir:${ir0.x4} rgbc:${rgbc.x8} rgb2:${rgb2.x8}");
  }

  void ncdt() {
    ncds(vx0, vy0, vz0);
    ncds(vx1, vy1, vz1);
    ncds(vx2, vy2, vz2);
  }

  // MVMVA - Multiply Vector Matrix Add Vector
  // cmd: 010 10010 M V T sf lm 00000 010010 (0x12)
  // M: Matrix (0=RT, 1=LLM, 2=LCM, 3=Reserved)
  // V: Vector (0=V0, 1=V1, 2=V2, 3=IR/RGB)
  // T: Translation Vector (0=TR, 1=BK, 2=FC/Bugged, 3=None)
  void mvmva() {
    final matrixSel = cmd.shr17 & 3;
    final vectorSel = cmd.shr15 & 3;
    final transSel = cmd.shr13 & 3;

    final v = switch (vectorSel) {
      0 => v0,
      1 => v1,
      2 => v2,
      _ => ir,
    };

    final m = switch (matrixSel) {
      0 => rt, // RT
      1 => l, // LLM
      2 => lc, // LCM
      _ => (-r.shl4, r.shl4, ir0, rt13, rt13, rt13, rt22, rt22, rt22) // bug
    };

    final t = switch (transSel) {
      0 => tr,
      1 => (rbk, gbk, bbk),
      2 => (rfc, gfc, bfc),
      _ => (0, 0, 0), // No translation
    };

    if (transSel == 2) {
      // GTE Bug: flags are set by the 1st component but result is from the 2nd and 3rd
      ir1 = co44(1, rfc.shl12 + m.$1 * v.$1) >> shift;
      ir2 = co44(2, gfc.shl12 + m.$4 * v.$1) >> shift;
      ir3 = co44(3, bfc.shl12 + m.$7 * v.$1) >> shift;

      final x = m.$2 * v.$2 + m.$3 * v.$3;
      final y = m.$5 * v.$2 + m.$6 * v.$3;
      final z = m.$8 * v.$2 + m.$9 * v.$3;

      setMacAndIrV((x, y, z));
      return;
    }

    setMacAndIrV(multiplyMatrixT(m, v, t));
  }

  // NCS - Normal Color Single
  // cmd: 010 10010 0 0 0 sf lm 00000 011110 (0x1E)
  void ncs(int vx, int vy, int vz) {
    setMacAndIrV(multiplyMatrix(l, (vx, vy, vz)));
    setMacAndIrV(multiplyMatrixT(lc, ir, bk));
    pushColor();
  }

  // NCCS - Normal Color Color Single
  void nccs(int vx, int vy, int vz) {
    setMacAndIrV(multiplyMatrix(l, (vx, vy, vz)));
    setMacAndIrV(multiplyMatrixT(lc, ir, bk));
    setMacAndIrV(rgb.dot(ir));
    pushColor();
  }

  // CC - Color Color
  void cc() {
    setMacAndIrV(multiplyMatrixT(lc, ir, bk));
    setMacAndIrV(rgb.dot(ir));
    pushColor();
  }

  // CDP - Color Depth Cue
  void cdp() {
    setMacAndIrV(multiplyMatrixT(lc, ir, bk));

    final ir_ = (ir1, ir2, ir3);

    setMacAndIrVlm0((fc << 12) - rgb.dot(ir));
    setMacAndIrV(rgb.dot(ir_) + ir * ir0);
    pushColor();
  }

  // NCT - Normal Color Triple
  void nct() {
    ncs(vx0, vy0, vz0);
    ncs(vx1, vy1, vz1);
    ncs(vx2, vy2, vz2);
  }

  // SQR - Square
  void sqr() {
    setMacAndIrV(ir.dot(ir));
  }

  // DCPL - Depth Cue Color Light
  void dcpl() {
    final ir_ = ir;

    setMacAndIrVlm0((fc << 12) - rgb.dot(ir));
    setMacAndIrV(rgb.dot(ir_) + ir * ir0);
    pushColor();
  }

  // DPCS - Depth Cue Single
  void dpcs({bool useRgbc = true}) {
    final rgb1 = useRgbc
        ? rgb << 12
        : (rgb0.shl16 & 0xff0000, rgb0.shl8 & 0xff0000, rgb0 & 0xff0000);

    setMacAndIrVlm0((fc << 12) - rgb1);
    setMacAndIrV(rgb1 + ir * ir0);
    pushColor();
  }

  // DPCT - Depth Cue Triple
  void dpct() {
    dpcs(useRgbc: false);
    dpcs(useRgbc: false);
    dpcs(useRgbc: false);
  }

  // INTPL - Interpolate
  // cmd: 010 10010 0 0 0 sf lm 00000 010001 (0x11)
  void intpl() {
    final irs = ir << 12;

    setMacAndIrVlm0((fc << 12) - irs);
    setMacAndIrV(irs + ir * ir0);
    pushColor();
  }

  // GPF - General Purpose Interpolation Function
  void gpf() {
    setMacAndIrV(ir * ir0);
    pushColor();
  }

  // GPL - General Purpose Interpolation Function with Base
  void gpl() {
    setMacAndIrV(((mac1.rel32, mac2.rel32, mac3.rel32) << shift) + ir * ir0);
    pushColor();
  }

  // NCCT - Normal Color Color Triple
  void ncct() {
    nccs(vx0, vy0, vz0);
    nccs(vx1, vy1, vz1);
    nccs(vx2, vy2, vz2);
  }

  // OP - Outer Product
  void op() {
    final opx = rt22 * ir3 - rt33 * ir2;
    final opy = rt33 * ir1 - rt11 * ir3;
    final opz = rt11 * ir2 - rt22 * ir1;

    setMacAndIrV((opx, opy, opz));
  }
}
