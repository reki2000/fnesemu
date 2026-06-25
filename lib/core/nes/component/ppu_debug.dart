import 'package:fnesemu/util/int.dart';
// Project imports:
import 'ppu.dart';

extension PpuDebugger on Ppu {
  String dump({showSpriteVram = false}) {
    return "c1:${ctl1.x2} "
        "c2:${ctl2.x2} "
        "s:${status.x2} "
        "x:${scrollX.toString().padLeft(3)} "
        "y:${scrollY.toString().padLeft(3)} "
        "tmp:${tmpVramAddr.x4} "
        "fineX:${fineX.x2} "
        "addr:${vramAddr.x4} "
        "obj:${objAddr.x2} "
        "line:$scanLine "
        "\n"
        "${showSpriteVram ? dumpObjVram(objAddr, objAddr) : ''}";
  }

  String dumpObjVram(int addr, int target) {
    addr &= 0xf0;
    var str = "obj: ${addr.x4}:";
    for (int i = 0; i < 16; i++) {
      str += ((addr + i) == target
              ? "["
              : (addr + i) == target + 1
                  ? "]"
                  : " ") +
          objRam[(addr + i) & 0xff].x2;
    }
    return "$str\n";
  }
}
