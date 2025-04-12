String _previousLog = "";
int _supressCount = 0;

class DebugStatus {
  int clock = 0;
  int frame = 0;
  int scanline = 0;

  int breakClock = -1;

  @override
  String toString() => "$frame:$scanline:$clock";
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
