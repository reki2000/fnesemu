import 'package:fnesemu/core/md/z80/z80.dart';

extension OpCb on Z80 {
  bool execCb(int op) {
    final src = op & 0x07;
    int val = readReg(src);

    switch (op & 0xc0) {
      case 0x00: // rot
        val = switch (op & 0x38) {
          0x00 => rlc8(val),
          0x08 => rrc8(val),
          0x10 => rl8(val),
          0x18 => rr8(val),
          0x20 => sla8(val),
          0x28 => sra8(val),
          0x38 => srl8(val),
          _ => val, // Default case if none of the above match
        };
        break;
      case 0x40: // bit
        final bit = op & 0x38 >> 3;
        regs.flagZ = (val & (1 << bit)) == 0;
        regs.flagH = true;
        regs.flagN = false;
        break;
      case 0x80: // res
        val &= ~(1 << (op & 0x38 >> 3));
        break;
      case 0xc0: // set
        val |= 1 << (op & 0x38 >> 3);
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
