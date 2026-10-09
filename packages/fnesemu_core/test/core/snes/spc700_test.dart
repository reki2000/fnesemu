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

    test('ADC / SBC (X),(Y) store the result to (X)', () {
      final snd = soundCpuAt([0x99, 0x80, 0xb9]); // ADC (X),(Y); SETC; SBC
      snd.x = 0x10;
      snd.y = 0x20;
      snd.ram[0x10] = 5;
      snd.ram[0x20] = 3;
      snd.exec();
      expect(snd.ram[0x10], 8);
      expect(snd.ram[0x20], 3);

      snd.exec();
      snd.exec();
      expect(snd.ram[0x10], 5);
      expect(snd.ram[0x20], 3);
    });
  });
}
