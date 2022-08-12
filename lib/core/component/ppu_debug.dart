// Project imports:
import 'ppu.dart';
import '../../util.dart';

extension PpuDebugger on Ppu {
  String dump({showSpriteVram = false}) {
    return "ctl1:${hex8(ctl1)} "
        "ctl2:${hex8(ctl2)} "
        "status:${hex8(status)} "
        "tmp:${hex16(tmpVramAddr)} "
        "fineX:${hex8(fineX)} "
        "addr:${hex16(vramAddr)} "
        "obj:${hex8(objAddr)} "
        "line:$scanLine "
        "cycle:$cycle\n"
        "${showSpriteVram ? dumpObjVram(objAddr, objAddr) : ''}";
  }

  String dumpObjVram(int addr, int target) {
    addr &= 0xf0;
    var str = "obj: " + hex16(addr) + ":";
    for (int i = 0; i < 16; i++) {
      str += ((addr + i) == target
              ? "["
              : (addr + i) == target + 1
                  ? "]"
                  : " ") +
          hex8(objRam[(addr + i) & 0xff]);
    }
    return str + "\n";
  }
}
