import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/core/core_api.dart';
import 'package:fnesemu/core/core_empty.dart';

class _Core extends EmptyCore {
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
    final debugger = Debugger(_Core());
    expect(debugger.opt.targetCpuNo, 2);
    debugger.setDebugView(true);
    expect(debugger.disasmAddress(7), 112);
    expect(debugger.cpuInfo(7).pcBitWidth, 24);
    expect(debugger.nextPc(7), 114);
    expect(debugger.disasm(7, -1).$1, 'cpu 7');
  });
}
