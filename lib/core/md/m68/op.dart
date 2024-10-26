import 'package:fnesemu/core/md/m68/op_0.dart';
import 'package:fnesemu/core/md/m68/op_4.dart';
import 'package:fnesemu/core/md/m68/op_6.dart';
import 'package:fnesemu/core/md/m68/op_c.dart';
import 'package:fnesemu/core/md/m68/op_e.dart';
import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Op on M68 {
  bool exec() {
    pc0 = pc;
    final op = op0 = pc16();

    try {
      switch (op >> 12) {
        case 0x00:
          return exec0(op);
        case 0x01:
        case 0x02:
        case 0x03:
          final size = size2[op >> 12 & 0x03];
          final src = op & 0x07;
          final modeSrc = op >> 3 & 0x07;
          final dst = op >> 9 & 0x07;
          final modeDst = op >> 6 & 0x07;

          final value = readAddr(size, modeSrc, src);

          if (modeDst != 1) {
            nf = value.msb(size);
            zf = value.mask(size) == 0;
            vf = cf = false;
          }

          debug(
              "size:$size src:$src modeSrc:$modeSrc dst:$dst modeDst:$modeDst");

          if (modeDst != 0 && modeDst != 1) {
            addr0 = addressing(size, modeDst, dst);
            debug("addr0:${addr0.mask32.hex32}");
          } else if (modeDst == 1) {
            a[dst] = value.rel(size).mask32;
            return true;
          }

          writeAddr(size, modeDst, dst, value);
          if (modeDst == 3) {
            postInc(dst, size);
          }

          return true;

        case 0x04:
          return exec4(op);
        case 0x05:
          return exec5(op);
        case 0x06:
          return exec6(op);

        case 0x07:
          // moveq
          final val = op.mask8.rel8.mask32;
          d[op >> 9 & 0x07] = val;
          nf = val.msb(4);
          zf = val == 0;
          vf = cf = false;
          return true;

        case 0x08:
          return exec8(op);
        case 0x09:
          return exec9(op);
        case 0x0a:
          return execA(op);
        case 0x0b:
          return execB(op);
        case 0x0c:
          return execC(op);
        case 0x0d:
          return execD(op);
        case 0x0e:
          return execE(op);
        case 0x0f:
          return execF(op);
      }
    } catch (e) {
      if (e is BusError) {
        busError(e.addr, e.pc, op, e.read, e.inst);
        return true;
      }

      rethrow;
    }

    return false;
  }

  bool exec1(int op) => false;
  bool exec2(int op) => false;

  bool exec9(int op) => false;
  bool execA(int op) => false;

  bool execF(int op) => false;
}
