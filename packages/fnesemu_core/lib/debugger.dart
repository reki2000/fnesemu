import 'dart:async';

import 'src/core_debug.dart';
import 'src/internal/buffered_stream.dart';
import 'src/internal/tracer.dart';
import 'src/internal/video_refresh.dart';
import 'src/types.dart';
import 'src/video_debug.dart';

/// Immutable settings and display data delivered to debugger clients.
class DebugState {
  final bool showDebugView, showVdc, showDisasm, showMem, log;
  final int memAddress, breakPoint, breakClock, targetCpuNo;
  final String text;
  final List<int> disasmAddress;
  final List<String> traceLog;
  final DebugView view;
  final LayerView layerView;
  final bool videoLive;
  final int patternBlockSize;
  final bool alternativeBackground,
      patternNumbers,
      patternBounds,
      viewportBounds,
      hasPatterns;
  final List<DebugVideoPanel> videoPanels;

  DebugState({
    required this.showDebugView,
    required this.showVdc,
    required this.showDisasm,
    required this.showMem,
    required this.log,
    required this.memAddress,
    required this.breakPoint,
    required this.breakClock,
    required this.targetCpuNo,
    required this.text,
    required Iterable<int> disasmAddress,
    required Iterable<String> traceLog,
    required this.view,
    required this.layerView,
    required this.videoLive,
    required this.patternBlockSize,
    required this.alternativeBackground,
    required this.patternNumbers,
    required this.patternBounds,
    required this.viewportBounds,
    required this.hasPatterns,
    required Iterable<DebugVideoPanel> videoPanels,
  })  : disasmAddress = List.unmodifiable(disasmAddress),
        traceLog = List.unmodifiable(traceLog),
        videoPanels = List.unmodifiable(videoPanels);
}

enum _DebugRunMode { none, step, next, stepOut, line, frame }

class Debugger {
  static const _maxTraceLines = 50000;

  CoreDebug _core;
  final Future<void> Function()? _onRun, _onStop;

  Debugger(this._core,
      {Future<void> Function()? onRun, Future<void> Function()? onStop})
      : _onRun = onRun,
        _onStop = onStop {
    setCore(_core);
  }

  bool _showDebugView = false, _showVdc = false, _showDisasm = true;
  bool _showMem = false, _logging = false;
  bool _traceLimitReached = false;
  int _memAddress = 0, _breakPoint = -1, _breakClock = 0, _targetCpuNo = 0;
  bool _breakClockEnabled = false;
  String _text = '';
  List<int> _disasmAddress = [];
  final _log = <String>[];
  late DebugState _state;
  DebugView _view = DebugView.cpu;
  LayerView _layerView = LayerView.screen;
  bool _videoLive = false;
  final _videoRefresh = VideoRefresh();
  bool _alternativeBackground = false,
      _patternNumbers = false,
      _patternBounds = false,
      _viewportBounds = true;
  int _paletteOffset = 0;
  int _patternBlockSize = 8;
  List<DebugVideoPanel> _videoPanels = [];

  DebugState get state => _state;
  List<CpuInfo> get cpuInfos => List.unmodifiable(_core.cpuInfos);
  CpuInfo cpuInfo(int no) => _core.cpuInfos.firstWhere((cpu) => cpu.no == no);

  final _debugStream = BufferedStreamController<DebugState>();
  Stream<DebugState> get debugStream => _debugStream.stream;

  int _paletteCount = 1, _vramBits = 8;
  int get paletteCount => _paletteCount;
  int get vramBits => _vramBits;
  _DebugRunMode _runMode = _DebugRunMode.none;
  int? _commandCpuNo, _temporaryBreakPoint, _initialStackPointer;
  int _commandGeneration = 0;

  /// Controller integration: attach inspection data after replacing the core.
  void setCore(CoreDebug core, {int paletteCount = 1, int vramBits = 8}) {
    cancelExecution();
    _paletteCount = paletteCount;
    _vramBits = vramBits;
    _core = core;
    _targetCpuNo = core.cpuInfos.isEmpty ? 0 : core.cpuInfos.first.no;
    _disasmAddress = List.filled(core.cpuInfos.length, 0);
    _resetTrace();
    if (_view == DebugView.patterns && !core.hasPatternTables) {
      _view = DebugView.layers;
    }
    refreshVideo();
  }

  /// Controller integration: resets transient execution and tracing state.
  void reset() {
    cancelExecution();
    _breakClockEnabled = _breakClock > 0;
    _resetTrace();
    refreshVideo();
  }

  void setDebugView(bool show) {
    _showDebugView = show;
    if (!show) {
      _videoLive = false;
      _resetTrace();
    }
    refreshVideo();
  }

  void setBreakPoint(int address) {
    _breakPoint = address;
    pushStream();
  }

  void setBreakClock(int clock) {
    _breakClock = clock;
    _breakClockEnabled = clock > 0;
    pushStream();
  }

  void selectCpu(int cpuNo) {
    cpuInfo(cpuNo); // reject identities not advertised by the core
    _targetCpuNo = cpuNo;
    _memAddress &= (1 << cpuInfo(cpuNo).pcBitWidth) - 1;
    _restartTrace();
    pushStream();
  }

  void selectNextCpu() {
    final cpus = _core.cpuInfos;
    if (cpus.isEmpty) return;
    final index = cpus.indexWhere((cpu) => cpu.no == _targetCpuNo);
    selectCpu(cpus[(index + 1) % cpus.length].no);
  }

  void setMemoryAddress(int address) {
    if (_core.cpuInfos.isEmpty) return;
    _memAddress = address & ((1 << cpuInfo(_targetCpuNo).pcBitWidth) - 1);
    pushStream();
  }

  void setDisasmVisible(bool show) {
    _showDisasm = show;
    pushStream();
  }

  void setMemoryVisible(bool show) {
    _showMem = show;
    pushStream();
  }

  void setVideoVisible(bool show) {
    _showVdc = show;
    pushStream();
  }

  void _resetTrace() {
    _logging = false;
    _traceLimitReached = false;
    _log.clear();
    _restartTrace();
  }

  void setLogEnabled(bool enabled) {
    _logging = enabled;
    _traceLimitReached = false;
    _log.clear();
    _restartTrace();
    pushStream();
  }

  void toggleDisasm() => setDisasmVisible(!_showDisasm);
  void toggleMem() => setMemoryVisible(!_showMem);
  void toggleVdc() => setVideoVisible(!_showVdc);
  void startTrace() => setLogEnabled(true);
  String traceText() {
    _tracer?.finish();
    pushStream();
    return _log.join("\n");
  }

  void toggleLog() => setLogEnabled(!_logging);

  void clearLog() {
    _traceLimitReached = false;
    _log.clear();
    _restartTrace();
    pushStream();
  }

  void selectView(DebugView view) {
    _view = view == DebugView.patterns && !_core.hasPatternTables
        ? DebugView.layers
        : view;
    refreshVideo();
  }

  void setVideoLive(bool enabled) {
    _videoLive = enabled;
    refreshVideo();
  }

  void setLayerView(LayerView view) {
    _layerView = view;
    refreshVideo();
  }

  void setPatternBlockSize(int size) {
    if (size != 8 && size != 16 && size != 32) {
      throw ArgumentError.value(size, 'size');
    }
    _patternBlockSize = size;
    refreshVideo();
  }

  void selectNextPalette() {
    _paletteOffset++;
    refreshVideo();
  }

  void selectPreviousPalette() {
    _paletteOffset--;
    refreshVideo();
  }

  void setAlternativeBackground(bool alternative) {
    _alternativeBackground = alternative;
    refreshVideo();
  }

  void setPatternNumbersVisible(bool visible) {
    _patternNumbers = visible;
    pushStream();
  }

  void setPatternBoundsVisible(bool visible) {
    _patternBounds = visible;
    pushStream();
  }

  void setViewportBoundsVisible(bool visible) {
    _viewportBounds = visible;
    pushStream();
  }

  /// Captures only the active video view. Normal frame notifications reuse the
  /// last stopped capture unless live rendering explicitly requests updates.
  void refreshVideo() {
    _videoRefresh.capture(_captureVideo);
    pushStream();
  }

  void _captureVideo() {
    if (!_showDebugView || _view == DebugView.cpu) {
      _videoPanels = [];
    } else if (_view == DebugView.layers) {
      _videoPanels = [
        for (final layer in _core.videoLayers)
          DebugVideoPanel(
              layer.name,
              layer.capture(_layerView == LayerView.map && layer.hasMap),
              _alternativeBackground
                  ? layer.alternativeBackground
                  : layer.originalBackground,
              kind: layer.kind,
              row: layer.row)
      ];
    } else {
      _videoPanels = [
        for (final table in _core.patternTables)
          table.capture(_paletteOffset, _alternativeBackground,
              blockSize: _patternBlockSize)
      ];
    }
  }

  Future<void> pause() async {
    cancelExecution();
    if (_core.cpuInfos.isEmpty) return;
    final stop = _onStop;
    if (stop == null) {
      throw StateError('Debugger is not connected to an execution controller');
    }
    await stop();
  }

  Future<void> run() async {
    _traceLimitReached = false;
    cancelExecution();
    if (_core.cpuInfos.isEmpty) return;
    final resume = _onRun;
    if (resume == null) {
      throw StateError('Debugger is not connected to an execution controller');
    }
    await resume();
  }

  Future<void> step() => _execute(_DebugRunMode.step);
  Future<void> next() => _execute(_DebugRunMode.next);
  Future<void> stepOut() => _execute(_DebugRunMode.stepOut);
  Future<void> runToLine() => _execute(_DebugRunMode.line);
  Future<void> runToFrame() => _execute(_DebugRunMode.frame);

  Future<void> _execute(_DebugRunMode mode) async {
    if (_core.cpuInfos.isEmpty) return;
    _traceLimitReached = false;
    final resume = _onRun;
    final stop = _onStop;
    if (resume == null || stop == null) {
      throw StateError('Debugger is not connected to an execution controller');
    }
    final generation = ++_commandGeneration;
    await stop();
    // A reset, replacement or newer command supersedes a waiting request.
    if (generation != _commandGeneration || _core.cpuInfos.isEmpty) return;
    _clearTemporaryStop();
    _runMode = mode;
    _commandCpuNo = _targetCpuNo;
    if (mode == _DebugRunMode.next) {
      _temporaryBreakPoint = nextPc(_targetCpuNo);
    } else if (mode == _DebugRunMode.stepOut) {
      _initialStackPointer = _core.stackPointer(_targetCpuNo);
    }
    _showDebugView = true;
    pushStream();
    await resume();
  }

  /// Controller integration: cancel outstanding requests on explicit stop,
  /// normal resume, reset or core replacement. Persistent settings survive.
  void cancelExecution() {
    _commandGeneration++;
    _clearTemporaryStop();
  }

  void _clearTemporaryStop() {
    _runMode = _DebugRunMode.none;
    _commandCpuNo = _temporaryBreakPoint = _initialStackPointer = null;
  }

  /// Controller integration: called when the execution loop has stopped.
  void executionStopped() {
    _clearTemporaryStop();
    _tracer?.finish();
    refreshVideo();
  }

  // These queries do not allocate display snapshots in the instruction loop.
  bool get needsInstructionLoop =>
      _showDebugView ||
      _runMode != _DebugRunMode.none ||
      _logging ||
      _breakPoint >= 0 ||
      _breakClockEnabled;
  bool get stepInstructions =>
      _runMode != _DebugRunMode.none ||
      _breakPoint >= 0 ||
      _breakClockEnabled ||
      _logging;
  bool get stopAfterLine => _runMode == _DebugRunMode.line;
  bool get stopAfterFrame => _runMode == _DebugRunMode.frame;
  int get executionCpuNo => _commandCpuNo ?? _targetCpuNo;
  bool get logEnabled => _logging;

  /// Controller integration: evaluate stops after the target CPU executes.
  bool shouldPause(ExecResult result, int clock) {
    if (!needsInstructionLoop || !result.executed(executionCpuNo)) return false;
    final clockReached = _breakClockEnabled && _breakClock <= clock;
    final pc = _core.programCounter(executionCpuNo);
    final pause = _traceLimitReached ||
        clockReached ||
        (_breakPoint >= 0 && pc == _breakPoint) ||
        (_temporaryBreakPoint != null && pc == _temporaryBreakPoint) ||
        _runMode == _DebugRunMode.step ||
        (_runMode == _DebugRunMode.stepOut &&
            _core.stackPointer(executionCpuNo) > _initialStackPointer!);
    if (pause) _breakClockEnabled = _breakClock > clock;
    return pause;
  }

  /// Controller integration: record inspection data before an instruction.
  void recordTrace() {
    if (!_logging || _pendingTrace != null) return;
    final log = _core.trace(_targetCpuNo);
    _pendingTrace = TraceLog(
        log.pc, log.cycle, log.disasm, log.regs, List<int>.of(log.state),
        frame: log.frame,
        scanline: log.scanline,
        flow: log.flow,
        instructionKey: log.instructionKey);
  }

  TraceLog? _pendingTrace;

  /// Commit only after the selected CPU executes; other CPUs may run first.
  void completeTrace(ExecResult result) {
    final pending = _pendingTrace;
    if (!_logging || pending == null || !result.executed(_targetCpuNo)) return;
    _pendingTrace = null;
    _tracer?.addTraceLog(pending,
        nextPc: result.stopped ? null : _core.programCounter(_targetCpuNo));
    if (_traceLimitReached && _logging) {
      // Keep the captured lines available for Copy, but stop recording so a
      // later explicit Run can resume emulation without immediately stopping.
      _logging = false;
      _restartTrace();
    }
  }

  /// Controller integration: publish a fresh immutable display snapshot.
  void pushStream({bool frameRendered = false}) {
    if (frameRendered &&
        _videoLive &&
        _view != DebugView.cpu &&
        _showDebugView &&
        _videoRefresh.ready) {
      _videoRefresh.capture(_captureVideo);
    }
    _text = _showDebugView
        ? _core.dump(showZeroPage: true, showStack: true, showApu: true)
        : '';
    if (_showDebugView) {
      _disasmAddress = [
        for (final cpu in _core.cpuInfos) _core.programCounter(cpu.no)
      ];
    }
    _state = DebugState(
      showDebugView: _showDebugView,
      showVdc: _showVdc,
      showDisasm: _showDisasm,
      showMem: _showMem,
      log: _logging,
      memAddress: _memAddress,
      breakPoint: _breakPoint,
      breakClock: _breakClock,
      targetCpuNo: _targetCpuNo,
      text: _text,
      disasmAddress: _disasmAddress,
      traceLog: _log,
      view: _view,
      layerView: _layerView,
      videoLive: _videoLive,
      patternBlockSize: _patternBlockSize,
      alternativeBackground: _alternativeBackground,
      patternNumbers: _patternNumbers,
      patternBounds: _patternBounds,
      viewportBounds: _viewportBounds,
      hasPatterns: _core.hasPatternTables,
      videoPanels: _videoPanels,
    );
    _debugStream.add(_state);
  }

  Tracer? _tracer;
  final _traceStream = StreamController<String>.broadcast(sync: true);
  StreamSubscription<String>? _traceSubscription;

  void _restartTrace() {
    _traceSubscription?.cancel();
    _traceSubscription = null;
    _tracer = null;
    _pendingTrace = null;
    if (!_logging || _core.cpuInfos.isEmpty) return;
    _tracer = Tracer(_traceStream, mode: TraceRepeatMode.path);
    _traceSubscription = _traceStream.stream.listen((line) {
      if (_log.length >= _maxTraceLines) return;
      _log.add(line.replaceAll('\n', ''));
      if (_log.length == _maxTraceLines) _traceLimitReached = true;
    });
  }

  int nextPc(int cpuNo) {
    final pc = _core.programCounter(cpuNo);
    final (_, inc) = disasm(cpuNo, pc);
    return (pc + inc) & ((1 << cpuInfo(cpuNo).pcBitWidth) - 1);
  }

  int stackPointer(int cpuNo) => _core.stackPointer(cpuNo);

  int disasmAddress(int cpuNo) =>
      _disasmAddress[_core.cpuInfos.indexWhere((cpu) => cpu.no == cpuNo)];

  (String, int) disasm(int cpuNo, int addr) {
    final mask = (1 << cpuInfo(cpuNo).pcBitWidth) - 1;
    final (text, length) = _core.disasm(cpuNo, addr & mask);
    return (text, length > 0 ? length : 1);
  }

  List<int> dumpVram() => _core.vram;
  int read(int addr, {int? cpuNo}) => _core.read(cpuNo ?? _targetCpuNo, addr);
  ImageBuffer renderBg() => _core.renderBg();
  List<String> spriteInfo() => _core.spriteInfo();
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) =>
      _core.renderVram(useSecondBgColor, paletteNo);
  ImageBuffer renderColorTable(int paletteNo) =>
      _core.renderColorTable(paletteNo);
}
