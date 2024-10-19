import 'package:fnesemu/core/md/m68/op_alu.dart';
import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension OpE on M68 {
  bool execE(int op) {
    final ry = op & 0x07;
    final rx = op >> 9 & 0x07;

    if (op & 0xc0 == 0xc0) {
      // 1 bit shift ops on the effective address, size = WORD
      final mode = op >> 3 & 0x07;
      final aa = readAddr(2, mode, ry);

      switch (op >> 8 & 0x07) {
        case 0:
          // asr
          final r = asr(aa, 2, 1);
          writeAddr(2, mode, ry, r);
          return true;

        case 1:
          // asl
          final r = asl(aa, 2, 1);
          writeAddr(2, mode, ry, r);
          return true;

        case 2:
          // lsr
          return false;
        case 3:
          // lsl
          return false;
        case 4:
          // roxr
          return false;
        case 5:
          // roxl
          return false;
        case 6:
          // ror
          return false;
        case 7:
          // rol
          return false;
      }

      return false;
    } else {
      //
      final size = size0[op >> 6 & 0x03];

      int rot = 0;
      if (op.bit5) {
        // register
        rot = d[rx] & 0x3f;
      } else {
        // immed
        rot = rx == 0 ? 8 : rx;
      }

      switch ((op >> 2 & 0x06) | (op >> 8 & 0x01)) {
        case 0:
          // asr
          d[ry] = d[ry].setL(asr(d[ry], size, rot), size);
          return true;

        case 1:
          // asl
          d[ry] = d[ry].setL(asl(d[ry], size, rot), size);
          return true;

        case 2:
          // lsr
          return false;
        case 3:
          // lsl
          return false;
        case 4:
          // roxr
          return false;
        case 5:
          // roxl
          return false;
        case 6:
          // ror
          return false;
        case 7:
          // rol
          return false;
      }
    }

    return false;
  }
}
