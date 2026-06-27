import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension M68Debug on M68 {
  String debug() {
    final rega = 'a:${a.map((e) => e.x8).join(' ')}';
    final regd = 'd:${d.map((e) => e.x8).join(' ')}';
    final regs =
        'sr:${sr.x8} usp:${usp.x8} ssp:${ssp.x8} pc:${pc.x8} cl:$clocks';

    const f = "XNZVC";
    final flags = List.generate(
        f.length,
        (i) => "$f${f.toLowerCase()}"[
            (sr << i & (1 << f.length - 1) != 0) ? i : f.length + i]).join();
    return '$rega $regd $flags $regs';
  }
}
