String _previousLog = "";
int _supressCount = 0;

void debugLog(String s) {
  if (s == _previousLog) {
    _supressCount++;
    return;
  }

  if (_supressCount > 0) {
    print("... (supressed $_supressCount times)");
    _supressCount = 0;
  }

  print(s);
  _previousLog = s;
}
