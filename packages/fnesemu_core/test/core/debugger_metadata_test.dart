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

}
