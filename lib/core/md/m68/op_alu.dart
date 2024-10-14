import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension OpAlu on M68 {
  int add(int a, int b, int size) {
    final r = a + b;
    print("r: ${r.hex32} a: ${a.hex32} b: ${b.hex32} xf: $xf");

    zf = r.mask(size) == 0;
    xf = cf = r.over(size);
    nf = r.msb(size);
    vf = (~(a ^ b) & (a ^ r)).msb(size);

    return r.mask(size);
  }

  int sub(int a, int b, int size) {
    final r = a - b;
    print("r: ${r.hex32} a: ${a.hex32} b: ${b.hex32} xf: $xf");

    zf = zf && r.mask(size) == 0;
    xf = cf = r.over(size);
    nf = r.msb(size);
    vf = (~(a ^ b) & (a ^ r)).msb(size);

    return r.mask(size);
  }
}
