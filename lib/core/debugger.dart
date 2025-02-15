import 'dart:async';

import '../gui/debug/tracer.dart';
import '../util/util.dart';
import 'buffered_stream.dart';
import 'core.dart';
import 'types.dart';

/// Parameters for debugging features
class DebugOption {
  bool showDebugView = false;

  bool showVdc = false;
  bool showDisasm = true;
  bool showMem = false;

  int memAddress = 0;

  String text = "";

  bool log = false;

  int breakPoint = -1;
  int stackPointer = -1;
  List<int> disasmAddress = [];

  int targetCpuNo = 0;
}

class Debugger {
  Core core;
  DebugOption opt = DebugOption();

  Debugger(this.core) {
    setCore(core);
  }

  setCore(Core core) {
    this.core = core;
    opt.disasmAddress = List.filled(core.cpuInfos.length, 0);
  }

  List<CpuInfo> get cpuInfos => core.cpuInfos;

  final _debugStream = BufferedStreamController<DebugOption>();
  Stream<DebugOption> get debugStream => _debugStream.stream;

  void setDebugView(bool show) {
    opt.showDebugView = show;
    pushStream();
  }

  void pushStream() {
    if (!opt.showDebugView) {
      opt.text = "";
    } else {
      opt.text = core.dump(showZeroPage: true, showStack: true, showApu: true);
      for (int i = 0; i < cpuInfos.length; i++) {
        opt.disasmAddress[i] = core.programCounter(i);
      }
    }

    _debugStream.add(opt);
  }

  Tracer? _tracer;
  final _traceStream = StreamController<String>();
  StreamSubscription<String>? _traceSubscription;

  void toggleLog() {
    opt.log = !opt.log;
    pushStream();

    if (opt.log && _tracer == null) {
      // m68000
      // _tracer = Tracer(_traceStream, pcWidth: 6, start: 0, end: 248, maxDiffChars: 4);
      // z80
      _tracer = Tracer(_traceStream,
          pcWidth: 4, start: 0, end: 148, maxDiffChars: 12);
      // 6502

      _traceSubscription = _traceStream.stream.listen((log) {
        this.log.add(log.replaceAll("\n", ""));
      }, onDone: () => _traceSubscription?.cancel());
    } else {
      _traceSubscription?.cancel();
      _tracer = null;
    }
  }

  final log = List<String>.empty(growable: true);

  addLog(String log) {
    if (opt.log) _tracer?.addLog(log);
  }

  void toggleDisasm() {
    opt.showDisasm = !opt.showDisasm;
    pushStream();
  }

  int nextPc(int cpuNo) {
    final pc = core.programCounter(cpuNo);
    final next = pc + core.disasm(0, pc).i1;
    return next & ((1 << core.cpuInfos[cpuNo].addrBits) - 1);
  }

  int stackPointer(int cpuNo) => core.stackPointer(cpuNo);

  Pair<String, int> disasm(int cpuNo, int addr) => core.disasm(cpuNo, addr);

  void toggleVdc() {
    opt.showVdc = !opt.showVdc;
    pushStream();
  }

  void toggleMem() {
    opt.showMem = !opt.showMem;
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
