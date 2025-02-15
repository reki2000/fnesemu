// Project imports:
import '../../../util/util.dart';
import 'bus.dart';

extension BusDebugger on Bus {
  String debug({bool showVram = false, bool showChar = false}) {
    var dump = "";
    if (showVram) {
      for (int addr = 0; addr < 0x2000; addr += 16) {
        dump += dumpVram(addr, 0xffff);
      }
    }
    if (showChar) {
      for (int addr = 0; addr < 0x2000; addr += 16) {
        dump += dumpChar(addr, 0xffff);
      }
    }
    return dump;
  }

  String dumpChar(int addr, int target) {
    addr &= 0x1ff0;
    var str = "${hex16(addr)}:";
    for (int i = 0; i < 16; i++) {
      str += ((addr + i) == target
              ? "["
              : (addr + i) == target + 1
                  ? "]"
                  : " ") +
          hex8(mapper.readVram(addr + i));
    }
    return "$str\n";
  }

  String dumpVram(int addr, int target) {
    addr &= 0x1ff0;
    var str = "${hex16(0x2000 + addr)}:";
    for (int i = 0; i < 16; i++) {
      str += ((addr + i) == target
              ? "["
              : (addr + i) == target + 1
                  ? "]"
                  : " ") +
          hex8(vram[addr + i]);
    }
    return "$str\n";
  }
}
