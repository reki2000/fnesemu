import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Alu on M68 {
  int add(int a, int b, int size, {bool useXf = false}) {
    final r = a + b + (useXf && xf ? 1 : 0);
    // debug("add r: ${r.hex32} a: ${a.hex32} b: ${b.hex32} xf: $xf");

    final carryBits = (a & b) | ((a | b) & ~r);
    xf = cf = carryBits.msb(size);
    nf = r.msb(size);
    vf = (~(a ^ b) & (a ^ r)).msb(size); // output changed && input not differed
    zf = (!useXf || zf) && r.mask(size) == 0;

    return r.mask(size);
  }

  int sub(int a, int b, int size, {bool useXf = false, bool cmp = false}) {
    final r = a - b - (useXf && xf ? 1 : 0);
    // debug(
    //     "sub r: ${r.hex32} a: ${a.hex32} b: ${b.hex32} xf: $xf");

    final carryBits = (~a & b) | ((~a | b) & r);
    cf = carryBits.msb(size);
    if (!cmp) {
      xf = cf;
    }
    nf = r.msb(size);
    vf = ((a ^ b) & (a ^ r)).msb(size); // output changed && input differed
    zf = (!useXf || zf) && r.mask(size) == 0;

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
    // debug("or a:${a.hex32} b:${b.hex32} r:${r.hex32}");

    return r.mask(size);
  }

  int eor(int a, int b, int size) {
    final r = a ^ b;

    nf = r.msb(size);
    zf = r.mask(size) == 0;
    vf = false;
    cf = false;
    // debug("eor a:${a.hex32} b:${b.hex32} r:${r.hex32}");

    return r.mask(size);
  }

  int not(int a, int size) {
    final r = ~a;

    nf = r.msb(size);
    zf = r.mask(size) == 0;
    vf = false;
    cf = false;
    // debug("not a:${a.hex32} r:${r.hex32}");

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
    // debug("asr a:${a.hex32} size:$size rot:$rot r:${r.hex32}");
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
        // debug(
        //     "asl a:${a.hex32} size:$size rot:$rot r:${r.hex32} affectedBits:${affectedBits.hex32}");
        vf = (r & affectedBits) != 0 && (r & affectedBits) != affectedBits;
      }

      r <<= rot - 1;
      xf = cf = r.msb(size);
      r <<= 1;
      nf = r.msb(size);
    } else {
      nf = r.msb(size);
      cf = false;
      vf = false;
    }
    zf = r.mask(size) == 0;
    // debug("asl a:${a.hex32} size:$size rot:$rot r:${r.hex32}");
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
    // debug("lsr a:${a.hex32} size:$size rot:$rot r:${r.hex32}");
    return r.mask(size);
  }

  int lsl(int a, int size, int rot) {
    int r = a.mask(size);
    if (rot != 0) {
      r <<= rot - 1;
      xf = cf = r.msb(size);
      r <<= 1;
    } else {
      cf = false;
    }
    vf = false;
    nf = r.msb(size);
    zf = r.mask(size) == 0;
    // debug("lsl a:${a.hex32} size:$size rot:$rot r:${r.hex32}");
    return r.mask(size);
  }

  int ror(int a, int size, int rot) {
    int r = a.mask(size);
    if (rot == 0) {
      cf = false;
    } else {
      rot &= size.bits - 1;
      r = (r >> rot) | (r << (size.bits - rot)).mask(size);
      cf = r.msb(size);
    }
    vf = false;
    nf = r.msb(size);
    zf = r.mask(size) == 0;
    // debug("ror a:${a.hex32} size:$size rot:$rot r:${r.hex32}");
    return r.mask(size);
  }

  int rol(int a, int size, int rot) {
    int r = a.mask(size);
    if (rot == 0) {
      cf = false;
    } else {
      rot &= size.bits - 1;
      r = (r << rot).mask(size) | (r >> (size.bits - rot));
      cf = r.bit0;
    }
    vf = false;
    nf = r.msb(size);
    zf = r.mask(size) == 0;
    // debug("rol a:${a.hex32} size:$size rot:$rot r:${r.hex32}");
    return r.mask(size);
  }

  int roxr(int a, int size, int rot) {
    int r = a.mask(size);
    rot %= (size.bits + 1);
    if (rot == 0) {
      cf = xf;
    } else {
      final xBit = xf ? 1 << (size.bits - rot) : 0;
      cf = xf = (r << (size.bits - rot)).msb(size);
      r = (r >> rot) | (r << (size.bits + 1 - rot)).mask(size) | xBit;
    }
    vf = false;
    nf = r.msb(size);
    zf = r.mask(size) == 0;
    // debug("roxr a:${a.hex32} size:$size rot:$rot r:${r.hex32}");
    return r.mask(size);
  }

  int roxl(int a, int size, int rot) {
    int r = a.mask(size);
    rot %= (size.bits + 1);
    if (rot == 0) {
      cf = xf;
    } else {
      final xBit = xf ? 1 << (rot - 1) : 0;
      cf = xf = (r >> (size.bits - rot)).bit0;
      r = (r << rot).mask(size) | (r >> (size.bits + 1 - rot)) | xBit;
      // debug(
      //     "rot:$rot ${(r << rot).mask(size).hex32} ${(r >> (size.bits - rot + 1)).hex32} ${xBit.hex32}");
    }
    vf = false;
    nf = r.msb(size);
    zf = r.mask(size) == 0;
    // debug("roxl a:${a.hex32} size:$size rot:$rot r:${r.hex32}");
    return r.mask(size);
  }
}
