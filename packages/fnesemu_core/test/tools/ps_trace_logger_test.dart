import 'package:test/test.dart';
import '../../tool/ps_test.dart' show TraceLogger;

void main() {
  test('trace logger extracts jump target and exception PC', () {
    const regs =
        'r00:00000000 800a0000 00000000 94639271 r04:00000000 00000000 00000010 800f1638 r08:0007ffe0 00000000 800a2100 00000000 r12:00000001 00000000 00000000 00000000 r16:00000010 00000010 8009d3c8 00000000 r20:00000001 00000000 00000000 00000000 r24:00000001 00000000 800ddc74 00000f1c r28:8009dca8 801ffef0 801fffe8 8002d324 pc:8002d324 hi:0007ffe0 lo:0006ffe4 sr:40000401 cause:00000000 epc:800ddc74';
    expect(TraceLogger.extractToReg('jr r31', regs), 0x8002d324);
    expect(TraceLogger.extractEpc(regs), 0x800ddc74);
  });
}
