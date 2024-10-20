import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension OpAlu on M68 {
  int addx(int a, int b, int size) {
    final r = a + b + (xf ? 1 : 0);
    debug("addx size:$size r:${r.hex32} a:${a.hex32} b:${b.hex32} xf:$xf");

    xf = cf = r.over(size);
    nf = r.msb(size);
    vf = (~(a ^ b) & (a ^ r)).msb(size);
    zf = zf && r.mask(size) == 0;

    return r.mask(size);
  }

  int add(int a, int b, int size) {
    final r = a + b;
    debug("add r: ${r.hex32} a: ${a.hex32} b: ${b.hex32} xf: $xf");

    xf = cf = r.over(size);
    nf = r.msb(size);
    vf = (~(a ^ b) & (a ^ r)).msb(size); // output changed && input not differed
    zf = r.mask(size) == 0;

    return r.mask(size);
  }

  int sub(int a, int b, int size) {
    final r = a - b;
    debug(
        "sub r: ${r.mask32.hex32} a: ${a.mask32.hex32} b: ${b.mask32.hex32} xf: $xf");

    cf = r.over(size);
    nf = r.msb(size);
    vf = ((a ^ b) & (a ^ r)).msb(size); // output changed && input differed
    zf = r.mask(size) == 0;

    return r.mask(size);
  }

  int and(int a, int b, int size) {
    final r = a & b;

    nf = r.msb(size);
    zf = r.mask(size) == 0;
    vf = false;
    cf = false;

    return r.mask(size);
  }

  int or(int a, int b, int size) {
    final r = a | b;

    nf = r.msb(size);
    zf = r.mask(size) == 0;
    vf = false;
    cf = false;
    debug("or a:${a.hex32} b:${b.hex32} r:${r.hex32}");

    return r.mask(size);
  }

  int eor(int a, int b, int size) {
    final r = a ^ b;

    nf = r.msb(size);
    zf = r.mask(size) == 0;
    vf = false;
    cf = false;
    debug("eor a:${a.hex32} b:${b.hex32} r:${r.hex32}");

    return r.mask(size);
  }

  int asr(int a, int size, int rot) {
    int r = a.mask(size).rel(size);
    if (rot > size.bits) {
      xf = cf = false;
      r >>= rot;
    } else if (rot > 0) {
      r >>= rot - 1;
      xf = cf = r.bit0;
      r >>= 1;
    } else {
      cf = false;
    }
    vf = false;
    nf = a.msb(size);
    zf = r.mask(size) == 0;
    debug("asr a:${a.hex32} size:$size rot:$rot r:${r.mask32.hex32}");
    return r.mask(size);
  }

  int asl(int a, int size, int rot) {
    int r = a.mask(size);
    if (rot != 0) {
      if (rot >= size.bits) {
        // when rot size is more than operands' size, vf is set if any of bit is 1.
        vf = r != 0;
      } else {
        // mask to check if all of top "rot+1" bits are same; ex. rot=1, 0b1100.., rot=2, 0b1110..
        final affectedBits = (~((1 << (size.bits - rot - 1)) - 1)).mask(size);
        debug(
            "asl a:${a.hex32} size:$size rot:$rot r:${r.hex32} affectedBits:${affectedBits.hex32}");
        vf = (r & affectedBits) != 0 && (r & affectedBits) != affectedBits;
      }

      r <<= rot;
      xf = cf = r.over(size);
      nf = r.msb(size);
    } else {
      nf = r.msb(size);
      cf = false;
      vf = false;
    }
    zf = r.mask(size) == 0;
    debug("asl a:${a.hex32} size:$size rot:$rot r:${r.hex32}");
    return r.mask(size);
  }

  int lsr(int a, int size, int rot) {
    int r = a.mask(size);
    if (rot > size.bits) {
      xf = cf = false;
      r >>= rot;
    } else if (rot > 0) {
      r >>= rot - 1;
      xf = cf = r.bit0;
      r >>= 1;
    } else {
      cf = false;
    }
    vf = false;
    nf = r.msb(size);
    zf = r.mask(size) == 0;
    debug("lsr a:${a.hex32} size:$size rot:$rot r:${r.mask32.hex32}");
    return r.mask(size);
  }

  int lsl(int a, int size, int rot) {
    int r = a.mask(size);
    if (rot != 0) {
      r <<= rot;
      xf = cf = r.over(size);
    } else {
      cf = false;
    }
    vf = false;
    nf = r.msb(size);
    zf = r.mask(size) == 0;
    debug("lsl a:${a.hex32} size:$size rot:$rot r:${r.hex32}");
    return r.mask(size);
  }
}
