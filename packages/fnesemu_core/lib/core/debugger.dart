import 'dart:async';

import 'buffered_stream.dart';
import 'core.dart';
import 'tracer.dart';
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
  int breakClock = 0;
  bool breackClockEnabled = false;
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

  reset() {
    opt.breackClockEnabled = (opt.breakClock > 0);
    opt.stackPointer = -1;
    log.clear();
    pushStream();
  }

  int paletteCount = 1, vramBits = 8;

  setCore(Core core, {int paletteCount = 1, int vramBits = 8}) {
    this.paletteCount = paletteCount;
    this.vramBits = vramBits;
    this.core = core;
    opt.targetCpuNo = core.cpuInfos.isEmpty ? 0 : core.cpuInfos.first.no;
    opt.disasmAddress = List.filled(core.cpuInfos.length, 0);
  }

  List<CpuInfo> get cpuInfos => core.cpuInfos;
  CpuInfo cpuInfo(int no) => cpuInfos.firstWhere((cpu) => cpu.no == no);

  final _debugStream = BufferedStreamController<DebugOption>();
  Stream<DebugOption> get debugStream => _debugStream.stream;

  void setDebugView(bool show) {
    opt.showDebugView = show;
    pushStream();
  }

  /// ブレークポイントを設定（リセット時の初期化にも使用）
  void setBreakPoint(int breakPoint) {
    opt.breakPoint = breakPoint;
    pushStream();
  }

  /// ブレーククロックを設定（リセット時の初期化にも使用）
  void setBreakClock(int breakClock) {
    opt.breakClock = breakClock;
    opt.breackClockEnabled = (breakClock > 0);
    pushStream();
  }

  void pushStream() {
    if (!opt.showDebugView) {
      opt.text = "";
    } else {
      opt.text = core.dump(showZeroPage: true, showStack: true, showApu: true);
      for (int i = 0; i < cpuInfos.length; i++) {
        opt.disasmAddress[i] = core.programCounter(cpuInfos[i].no);
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
      final cpuInfo = this.cpuInfo(opt.targetCpuNo);
      _tracer = Tracer(_traceStream, maxDiffChars: cpuInfo.traceDiffs);

      _traceSubscription = _traceStream.stream.listen((log) {
        this.log.add(log.replaceAll("\n", ""));
      }, onDone: () => _traceSubscription?.cancel());
    } else {
      _traceSubscription?.cancel();
      _tracer = null;
    }
  }

  final log = List<String>.empty(growable: true);

  addLog(TraceLog log) {
    if (opt.log) _tracer?.addTraceLog(log);
  }

  void toggleDisasm() {
    opt.showDisasm = !opt.showDisasm;
    pushStream();
  }

  int nextPc(int cpuNo) {
    final pc = core.programCounter(cpuNo);
    final (_, inc) = disasm(cpuNo, pc);
    return (pc + inc) & ((1 << cpuInfo(cpuNo).pcBitWidth) - 1);
  }

  int stackPointer(int cpuNo) => core.stackPointer(cpuNo);

  int disasmAddress(int cpuNo) =>
      opt.disasmAddress[cpuInfos.indexWhere((cpu) => cpu.no == cpuNo)];

  (String, int) disasm(int cpuNo, int addr) {
    final mask = (1 << cpuInfo(cpuNo).pcBitWidth) - 1;
    final (text, length) = core.disasm(cpuNo, addr & mask);
    return (text, length > 0 ? length : 1);
  }

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
