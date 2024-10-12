import 'package:fnesemu/core/md/z80/z80.dart';

extension OpCb on Z80 {
  bool execCb(int op) {
    final src = op & 0x07;
    final op38 = op & 0x38;
    int val = readReg(src);

    switch (op & 0xc0) {
      case 0x00: // rot
        val = switch (op38) {
          0x00 => rlc8(val),
          0x08 => rrc8(val),
          0x10 => rl8(val),
          0x18 => rr8(val),
          0x20 => sla8(val),
          0x28 => sra8(val),
          0x30 => sll8(val),
          0x38 => srl8(val),
          _ => throw ("unreachable"),
        };
        break;
      case 0x40: // bit
        final bit = op38 >> 3;
        final v = val & (1 << bit);
        r.zf = v == 0;
        r.sf = (v & 0x80) != 0;
        r.hf = true;
        r.nf = false;
        r.pvf = r.zf;
        if (src == 6) cycles -= 3;
        break;
      case 0x80: // res
        val &= ~(1 << (op38 >> 3));
        break;
      case 0xc0: // set
        val |= 1 << (op38 >> 3);
        break;
    }

    writeReg(src, val);

    if (src == 6) {
      cycles += 9;
    } else {
      cycles += 8;
    }

    return true;
  }
}
