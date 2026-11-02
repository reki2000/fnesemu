import 'package:fnesemu_core/app_api.dart';
import 'package:test/test.dart';

class _DebugCore extends CoreDebug {
  @override
  bool jitEnabled = false;
  @override
  int cpuClocks = 0;
  @override
  int jitClocks = 0;

  @override
  List<CpuInfo> get cpuInfos =>
      const [CpuInfo(2, 'first', 20), CpuInfo(7, 'second', 24)];
  @override
  int programCounter(int cpuNo) => cpuNo * 16;
  @override
  (String, int) disasm(int cpuNo, int address) => ('cpu $cpuNo', 2);
}

void main() {
  test('JIT status follows core snapshots and clears on core replacement', () {
    final core = _DebugCore();
    final debugger = Debugger(core);
    expect(debugger.state.jitEnabled, isFalse);
    core.jitEnabled = true;
    debugger.pushStream();
    final snapshot = debugger.state;
    expect(snapshot.jitEnabled, isTrue);
    debugger.setCore(CoreDebug());
    expect(debugger.state.jitEnabled, isFalse);
    expect(snapshot.jitEnabled, isTrue);
  });

  test('JIT usage samples window deltas and remains stable between samples',
      () {
    final core = _DebugCore()
      ..jitEnabled = true
      ..cpuClocks = 100
      ..jitClocks = 20;
    final debugger = Debugger(core);
    debugger.executionStarted();
    expect(debugger.state.jitUsage, isNull);
    core.cpuClocks = 400;
    core.jitClocks = 260;
    debugger.sampleJitUsage();
    final snapshot = debugger.state;
    expect(snapshot.jitUsage, 0.8);
    core.cpuClocks = 500;
    core.jitClocks = 280;
    debugger.pushStream();
    expect(debugger.state.jitUsage, 0.8);
    debugger.sampleJitUsage();
    expect(debugger.state.jitUsage, 0.2);
    expect(snapshot.jitUsage, 0.8);
    debugger.executionStopped();
    core.cpuClocks = 550;
    debugger.executionStarted();
    expect(debugger.state.jitUsage, isNull);
    core.cpuClocks = 650;
    core.jitClocks = 380;
    debugger.sampleJitUsage();
    expect(debugger.state.jitUsage, 1.0);
  });

  test('JIT usage handles empty windows, clock resets and core replacement',
      () {
    final core = _DebugCore()..jitEnabled = true;
    final debugger = Debugger(core);
    debugger.sampleJitUsage();
    expect(debugger.state.jitUsage, isNull);
    core.cpuClocks = 100;
    debugger.sampleJitUsage();
    expect(debugger.state.jitUsage, 0.0);
    core.cpuClocks = 0;
    core.jitClocks = 0;
    debugger.sampleJitUsage();
    expect(debugger.state.jitUsage, isNull);
    core.cpuClocks = 100;
    core.jitClocks = 50;
    debugger.sampleJitUsage();
    expect(debugger.state.jitUsage, 0.5);
    debugger.reset();
    expect(debugger.state.jitUsage, isNull);
    debugger.setCore(CoreDebug());
    expect(debugger.state.jitEnabled, isFalse);
    expect(debugger.state.jitUsage, isNull);
  });

  test('debugger uses metadata CPU identities instead of list positions', () {
    final debugger = Debugger(_DebugCore());
    expect(debugger.state.targetCpuNo, 2);
    debugger.setDebugView(true);
    expect(debugger.disasmAddress(7), 112);
    expect(debugger.cpuInfo(7).pcBitWidth, 24);
    expect(debugger.nextPc(7), 114);
    expect(debugger.disasm(7, -1).$1, 'cpu 7');
  });
}
