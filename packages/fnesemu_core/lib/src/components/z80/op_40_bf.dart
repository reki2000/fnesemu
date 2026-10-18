import '../../util/int.dart';
import 'z80.dart';

extension Op40bf on Z80 {
  bool exec40bf(int op) {
    // halt
    if (op == 0x76) {
      r.pc = (r.pc - 1).mask16;
      halted = true;
      return true;
    }

    // ld r, r'
    if (op < 0x80) {
      final src = op.mask3;
      final dst = (op & 0x38).shr3;
      writeReg(dst, readReg(src));
      return true;
    }

    // alu r
    final val = readReg(op.mask3);
    switch (op & 0x38) {
      case 0x00: // add
        add8(val, 0);
        return true;
      case 0x08: // adc
        add8(val, r.cf ? 1 : 0);
        return true;
      case 0x10: // sub
        sub8(val, 0);
        return true;
      case 0x18: // sbc
        sub8(val, r.cf ? 1 : 0);
        return true;
      case 0x20: // and
        and8(val);
        return true;
      case 0x28: // xor
        xor8(val);
        return true;
      case 0x30: // or
        or8(val);
        return true;
      case 0x38: // cp
        cp8(val);
        return true;
    }

    return false;
  }
}
