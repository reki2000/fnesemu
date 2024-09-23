// Project imports:
import '../../../util.dart';
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
          "$i${w.enabled ? "*" : " "}$mode${hex16(w.freq).substring(1)},${hex8(w.volume)}-${hex8(w.volumeL)[1]}${hex8(w.volumeR)[1]} ";
    }
    return "psg: ${hex8(ampL)[1]}${hex8(ampL)[1]} $ch\n";
  }
}
