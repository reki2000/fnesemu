import 'package:fnesemu/util/int.dart';
// Project imports:
import 'psg.dart';

extension PsgDebugger on Psg {
  String dump() {
    var ch = "";
    for (int i = 0; i < 6; i++) {
      final w = waves[i];
      final mode = (i == 1 && lfoEnabled)
          ? "L"
          : w.noise
              ? "N"
              : w.dda
                  ? "D"
                  : "W";

      ch +=
          "$i${w.enabled ? "*" : " "}$mode${w.freq.x4.substring(1)},${w.volume.x2}-${w.volumeL.x2[1]}${w.volumeR.x2[1]} ";
    }
    return "psg: ${ampL.x2[1]}${ampL.x2[1]} $ch\n";
  }
}
