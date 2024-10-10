import 'package:fnesemu/core/md/z80/z80.dart';
import 'package:fnesemu/util.dart';

extension Z80Debug on Z80 {
  String _disasm(int addr) {
    return "";
  }

  String _reg() {
    return "AF:${hex16(regs.af)} BC:${hex16(regs.bc)} DE:${hex16(regs.de)} HL:${hex16(regs.hl)} IX:${hex16(regs.ixiy[0])} IY:${hex16(regs.ixiy[1])} SP:${hex16(regs.sp)}";
  }

  String trace() {
    return "${hex16(regs.pc)}:${_disasm(regs.pc)} ${_reg()} cy:$cycles"
        .toUpperCase();
  }
}
