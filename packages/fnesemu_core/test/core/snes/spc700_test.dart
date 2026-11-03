import 'package:test/test.dart';

import 'test_rom.dart';

void main() {
  group('sound cpu', () {
    test('BCS / BCC follow the carry flag', () {
      final bcs = soundCpuAt([0x80, 0xb0, 0x02, 0xe8, 0x11, 0xe8, 0x22]);
      for (int i = 0; i < 3; i++) {
        bcs.exec();
      }
      expect(bcs.a, 0x22);

      final bcc = soundCpuAt([0x60, 0x90, 0x02, 0xe8, 0x11, 0xe8, 0x22]);
      for (int i = 0; i < 3; i++) {
        bcc.exec();
      }
      expect(bcc.a, 0x22);

      final noBranch = soundCpuAt([0x60, 0xb0, 0x02, 0xe8, 0x11]);
      for (int i = 0; i < 3; i++) {
        noBranch.exec();
      }
      expect(noBranch.a, 0x11);
    });

  });
}
