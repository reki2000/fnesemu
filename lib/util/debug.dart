import 'package:fnesemu/util/int.dart';

String _previousLog = "";
int _supressCount = 0;

class DebugStatus {
  int clock = 0;
  int frame = 0;
  int scanline = 0;
  int pc = 0;

  @override
  String toString() =>
      "${pc.x8} $frame ${scanline.d3z} $clock";
}

final debugStatus = DebugStatus();

void debugLog(String s) {
  if (s == _previousLog) {
    _supressCount++;
    return;
  }

  if (_supressCount > 0) {
    print("... (supressed $_supressCount times)");
    _supressCount = 0;
  }

  print("$debugStatus $s");
  _previousLog = s;
}
