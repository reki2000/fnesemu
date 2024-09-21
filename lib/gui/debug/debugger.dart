import 'dart:async';

import '../../core_pce/pce.dart';
import '../../util.dart';
import 'trace.dart';

/// Parameters for debugging features
class DebugOption {
  bool showDebugView = false;
  int breakPoint = 0;
  bool log = false;
  bool showDisasm = true;
  int disasmAddress = 0;
  String text = "";
  bool showVdc = false;
}

class Debugger {
  final Pce _core;

  Debugger(this._core);

  // interafaces for debugging features
  final debugOption = DebugOption();

  final _debugStream = StreamController<DebugOption>.broadcast();
  Stream<DebugOption> get debugStream => _debugStream.stream;

  void setDebugView(bool show) {
    debugOption.showDebugView = show;
    pushStream();
  }

  void pushStream() {
    if (!debugOption.showDebugView) {
      debugOption.text = "";
    } else {
      debugOption.text =
          _core.dump(showZeroPage: true, showStack: true, showApu: true);
      debugOption.disasmAddress = _core.pc;
    }
    _debugStream.add(debugOption);
  }

  Trace? _tracer;
  final _traceStream = StreamController<String>.broadcast();
  StreamSubscription<String>? _traceSubscription;

  void toggleLog() {
    debugOption.log = !debugOption.log;
    pushStream();

    if (debugOption.log && _tracer == null) {
      _tracer = Trace(_traceStream);
      _traceSubscription = _traceStream.stream.listen((log) {
        print(log.replaceAll("\n", ""));
      }, onDone: () => _traceSubscription?.cancel());
    } else {
      _traceSubscription?.cancel();
      _tracer = null;
    }
  }

  addLog(String log) {
    if (debugOption.log) _tracer?.addLog(log);
  }

  void toggleDisasm() {
    debugOption.showDisasm = !debugOption.showDisasm;
    pushStream();
  }

  void toggleVdc() {
    debugOption.showVdc = !debugOption.showVdc;
    pushStream();
  }

  Pair<String, int> disasm(int addr) => _core.disasm(addr);

  List<int> dumpVram() => _core.dumpVram();
  int read(int addr) => _core.read(addr);
  List<int> dumpColorTable() => _core.dumpColorTable();
}
