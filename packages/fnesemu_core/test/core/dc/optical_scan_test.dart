import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/optical_audio.dart';
import 'package:test/test.dart';

import '../../support/cdda_fixture.dart';
import '../../support/fake_cdrom_drive.dart';

void main() {
  test('all speed parameter ranges select the four specified nominal rates',
      () {
    final drive = cddaRampDrive(20);
    for (var parameter = 0; parameter < 256; parameter++) {
      final rate = parameter <= 2
          ? 2
          : parameter <= 5
              ? 5
              : parameter <= 9
                  ? 9
                  : 16;
      final audio = DcOpticalAudio()..start(150, 151, 4);
      expect(audio.scan(reverse: false, speed: parameter), isTrue);
      expect(audio.scanning, isTrue);
      for (var frame = 0; frame < 32; frame++) {
        expect(audio.sample(drive), (frame * rate, -frame * rate));
      }
      expect(audio.repeatRemaining, 4);
    }
  });

  test('forward scan crosses sector boundaries and ignores the saved play end',
      () {
    final drive = cddaRampDrive(3);
    final audio = DcOpticalAudio()..start(150, 151, 5);
    audio.scan(reverse: false, speed: 0);
    for (var frame = 0; frame < 400; frame++) {
      expect(audio.sample(drive), (frame * 2, -frame * 2));
    }
    expect(audio.fad, 151);
    expect(audio.repeatRemaining, 5);
    expect(drive.reads, [150, 151]);
  });





  test('scan requires a saved live play range and reset/start clear its rate',
      () {
    final audio = DcOpticalAudio();
    expect(audio.scan(reverse: false, speed: 0), isFalse);
    audio.start(150, 151, 0);
    audio.scan(reverse: false, speed: 0);
    audio.reset();
    expect(audio.scanning, isFalse);
    expect(audio.scan(reverse: false, speed: 0), isFalse);
    audio.start(150, 151, 0);
    audio.scan(reverse: false, speed: 0);
    audio.start(150, 151, 0);
    final drive = cddaRampDrive(1);
    expect(audio.sample(drive), (0, 0));
    expect(audio.sample(drive), (1, -1));
    audio.fail();
    expect(audio.scanning, isFalse);
    expect(audio.scan(reverse: true, speed: 0), isFalse);
  });





}

class _PendingDrive extends FakeCdromDrive {
  _PendingDrive(super.sectors) : super(audioTracks: {1});
  bool pending = true;
  @override
  Uint8List? read(int lba) => pending ? null : super.read(lba);
}
