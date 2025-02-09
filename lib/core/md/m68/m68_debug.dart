import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension M68Debug on M68 {
  String debug() {
    final rega = 'a:${a.map((e) => e.hex32).join(' ')}';
    final regd = 'd:${d.map((e) => e.hex32).join(' ')}';
    final regs =
        'sr:${sr.hex32} usp:${usp.hex32} ssp:${ssp.hex32} pc:${pc.hex32} cl:$clocks';

    const f = "XNZVC";
    final flags = List.generate(
        f.length,
        (i) => "$f${f.toLowerCase()}"[
            (sr << i & (1 << f.length - 1) != 0) ? i : f.length + i]).join();
    return '$rega $regd $flags $regs';
  }
}
