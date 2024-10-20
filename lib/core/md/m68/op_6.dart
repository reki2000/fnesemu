import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Op6 on M68 {
  bool cond(int cond) => switch (cond) {
        0x00 => true,
        0x01 => false,
        0x02 => !cf && !zf, // hi
        0x03 => cf || zf, // low or same
        0x04 => !cf, // cc
        0x05 => cf, // cs
        0x06 => !zf, // ne
        0x07 => zf, // eq
        0x08 => !vf, // vc
        0x09 => vf, // vs
        0x0a => !nf, // pl
        0x0b => nf, // mi
        0x0c => (nf && vf) || (!nf && !vf), // ge
        0x0d => (nf && !vf) || (!nf && vf), // lt
        0x0e => !zf && ((nf && vf) || (!nf && !vf)), // gt
        0x0f => zf || (nf && !vf) || (!nf && vf), // le
        _ => throw "invalid cond: $cond",
      };

  bool exec6(int op) {
    final cc = op >> 8 & 0x0f;
    final pc0 = pc;
    final disp = switch (op.mask8) {
      0x00 => pc16().rel16,
      // 0xff => pc32().rel32,
      _ => op.mask8.rel8
    };

    if (cc == 0x01) {
      // bsr
      push32(pc);

      pc = (pc0 + disp).mask32;

      if (pc.bit0) {
        pc = pc.dec2;
        busError(pc0 + disp, op, true, true);
      }

      return true;
    }

    if (cond(cc)) {
      pc = (pc0 + disp).mask32;

      if (pc.bit0) {
        pc = pc.dec2;
        busError(pc0 + disp, op, true, true);
      }
    }

    return true;
  }
}
