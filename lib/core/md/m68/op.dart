import 'package:fnesemu/core/md/m68/op_0.dart';
import 'package:fnesemu/core/md/m68/op_6.dart';
import 'package:fnesemu/core/md/m68/op_c.dart';
import 'package:fnesemu/core/md/m68/op_e.dart';

import 'm68.dart';

extension Op on M68 {
  bool exec() {
    final op = pc16();

    try {
      switch (op >> 12) {
        case 0x00:
          return exec0(op);
        case 0x01:
        case 0x02:
        case 0x03:
          return exec3(op);
        case 0x04:
          return exec4(op);
        case 0x05:
          return exec5(op);
        case 0x06:
          return exec6(op);
        case 0x07:
          return exec7(op);
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
        busError(e.addr, op, e.read, e.inst);
        return true;
      }

      rethrow;
    }

    return false;
  }

  bool exec1(int op) => false;
  bool exec2(int op) => false;
  bool exec3(int op) => false;
  bool exec4(int op) => false;

  bool exec7(int op) => false;
  bool exec8(int op) => false;
  bool exec9(int op) => false;
  bool execA(int op) => false;
  bool execB(int op) => false;

  bool execF(int op) => false;
}
