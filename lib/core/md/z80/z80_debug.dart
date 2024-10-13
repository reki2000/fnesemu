import 'package:fnesemu/core/md/z80/z80.dart';
import 'package:fnesemu/util/util.dart';

extension Z80Debug on Z80 {
  String _disasm(int addr) {
    return "${hex8(bus.read(addr))} ${hex8(bus.read(addr + 1))} ${hex8(bus.read(addr + 1))}"
        .padRight(20, " ");
  }

  String _reg() {
    return "AF:${hex16(r.af)} BC:${hex16(r.bc)} DE:${hex16(r.de)} HL:${hex16(r.hl)} IX:${hex16(r.ixiy[0])} IY:${hex16(r.ixiy[1])} SP:${hex16(r.sp)}";
  }

  String trace() {
    return "${hex16(r.pc)}: ${_disasm(r.pc)} ${_reg()} cy:$cycles"
        .toUpperCase();
  }
}
