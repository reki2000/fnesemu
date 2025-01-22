import 'dart:async';

import '../gui/debug/tracer.dart';
import '../util/util.dart';
import 'core.dart';
import 'types.dart';

/// Parameters for debugging features
class DebugOption {
  bool showDebugView = false;

  bool showVdc = false;
  bool showDisasm = true;

  String text = "";

  bool log = false;
  int breakPoint = 0;
  List<int> disasmAddress = [];

  DebugOption(int maxCpuNo) : disasmAddress = List.filled(maxCpuNo, 0);
}

class Debugger {
  final Core core;

  Debugger(this.core) : debugOption = DebugOption(core.cpuInfos.length);

  // interafaces for debugging features
  DebugOption debugOption;

  List<String> get cpuInfos => core.cpuInfos;

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
      for (int i = 0; i < cpuInfos.length; i++) {
        debugOption.disasmAddress[i] = core.programCounter(i);
      }
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
      _tracer = Tracer(_traceStream, start: 0, end: 248, maxDiffChars: 4);
      _traceSubscription = _traceStream.stream.listen((log) {
        //print(log.replaceAll("\n", ""));
        this.log.add(log.replaceAll("\n", ""));
      }, onDone: () => _traceSubscription?.cancel());
    } else {
      _traceSubscription?.cancel();
      _tracer = null;
    }
  }

  final log = List<String>.empty(growable: true);

  addLog(String log) {
    if (debugOption.log) _tracer?.addLog(log);
  }

  void toggleDisasm() {
    debugOption.showDisasm = !debugOption.showDisasm;
    pushStream();
  }

  int nextPc(int cpuNo) =>
      (core.programCounter(cpuNo) +
          core.disasm(0, core.programCounter(cpuNo)).i1) &
      0xffff;

  Pair<String, int> disasm(int cpuNo, int addr) => core.disasm(cpuNo, addr);

  void toggleVdc() {
    debugOption.showVdc = !debugOption.showVdc;
    pushStream();
  }

  List<int> dumpVram() => core.vram;
  int read(int addr) => core.read(0, addr);
  ImageBuffer renderBg() => core.renderBg();
  List<String> spriteInfo() => core.spriteInfo();
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      core.renderVram(useSecondBgColor, paletteNo);
  ImageBuffer renderColorTable(int paletteNo) =>
      core.renderColorTable(paletteNo);
}
