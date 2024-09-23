import 'dart:async';

import '../gui/debug/tracer.dart';
import '../util.dart';
import 'pce/pce.dart';

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
  final Pce core;

  Debugger(this.core);

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
          core.dump(showZeroPage: true, showStack: true, showApu: true);
      debugOption.disasmAddress = core.pc;
    }
    _debugStream.add(debugOption);
  }

  Tracer? _tracer;
  final _traceStream = StreamController<String>.broadcast();
  StreamSubscription<String>? _traceSubscription;

  void toggleLog() {
    debugOption.log = !debugOption.log;
    pushStream();

    if (debugOption.log && _tracer == null) {
      _tracer = Tracer(_traceStream);
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

  int get nextPc => (core.pc + core.disasm(core.pc).i1) & 0xffff;

  Pair<String, int> disasm(int addr) => core.disasm(addr);

  List<int> dumpVram() => core.dumpVram();
  int read(int addr) => core.read(addr);
  List<int> dumpColorTable() => core.dumpColorTable();
}
