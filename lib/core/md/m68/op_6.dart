import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Op6 on M68 {
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
      pc = pc0 + disp;
      return true;
    }

    if (cond(cc)) {
      pc = pc0 + disp;
    }
    return true;
  }
}
