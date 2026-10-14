import 'package:fnesemu_core/app_api.dart';
import 'package:test/test.dart';

class _DebugCore extends CoreDebug {
  @override
  List<CpuInfo> get cpuInfos =>
      const [CpuInfo(2, 'first', 20), CpuInfo(7, 'second', 24)];
  @override
  int programCounter(int cpuNo) => cpuNo * 16;
  @override
  (String, int) disasm(int cpuNo, int address) => ('cpu $cpuNo', 2);
}

void main() {
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
