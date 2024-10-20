import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Op4 on M68 {
  bool exec4(int op) {
    final xn = op & 0x07;
    final dn = op >> 9 & 0x07;

    if (op & 0x01c0 == 0x01c0) {
      // lea
      return false;
    }

    if (op & 0x01c0 == 0x0180) {
      // chk
      final mode = op >> 3 & 0x07;
      final bound = readAddr(2, mode, xn).rel16;
      final data = d[dn].mask16.rel16;
      zf = vf = cf = false;
      nf = (data < 0)
          ? true
          : (data > bound)
              ? false
              : nf;
      debug(
          "chk dn:$dn xn:$xn mode:$mode bound:${bound.hex16} data:${data.hex16}");
      if (data < 0 || bound < data) {
        trap(0x18);
      }

      return true;
    }

    final size = size0[op >> 6 & 0x03];
    final mod = op >> 3 & 0x07;
    final reg = op & 0x07;

    switch (op >> 8 & 0x0f) {
      case 0x02:
        // clr
        readAddr(size, mod, reg); // to set addr0
        writeAddr(size, mod, reg, 0);
        nf = cf = vf = false;
        zf = true;
        return true;

      default:
        return false;
    }
  }
}
