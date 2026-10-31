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

  test('reverse scan reads descending sectors and pauses at accessible start',
      () {
    final drive = cddaRampDrive(3);
    final audio = DcOpticalAudio()..start(152, 153, 3);
    audio.scan(reverse: true, speed: 0);
    for (var value = 1176; value >= 0; value -= 2) {
      expect(audio.sample(drive), (value, -value));
    }
    expect(audio.fad, 150);
    expect(audio.playing, isFalse);
    expect(audio.scanning, isFalse);
    expect(audio.status, 0x12);
    expect(audio.repeatRemaining, 3);
    expect(drive.reads, [152, 151, 150]);
    expect(audio.sample(drive), (0, 0));
  });

  test('lead-out pauses instead of consuming repeats and supports reverse scan',
      () {
    final drive = cddaRampDrive(3);
    final audio = DcOpticalAudio()..start(150, 151, 15);
    audio.scan(reverse: false, speed: 10);
    for (var i = 0; i < 111; i++) {
      audio.sample(drive);
    }
    expect(audio.fad, 153);
    expect(audio.status, 0x12);
    expect(audio.repeatRemaining, 15);
    expect(audio.scan(reverse: true, speed: 255), isTrue);
    expect(audio.sample(drive), (1763, -1763));
    expect(audio.sample(drive), (1747, -1747));
    expect(drive.reads.last, 152);
  });

  test(
      'type-7 style resume returns to unit rate at the current source position',
      () {
    final drive = cddaRampDrive(3);
    final audio = DcOpticalAudio()..start(150, 152, 2);
    audio.scan(reverse: false, speed: 3);
    expect(audio.sample(drive), (0, 0));
    expect(audio.sample(drive), (5, -5));
    expect(audio.resume(), isTrue);
    expect(audio.scanning, isFalse);
    expect(audio.sample(drive), (10, -10));
    expect(audio.sample(drive), (11, -11));
    expect(audio.repeatRemaining, 2);
  });

  test('pause clears scan rate and a new scan may change direction', () {
    final drive = cddaRampDrive(3);
    final audio = DcOpticalAudio()..start(151, 153, 0);
    audio.pause();
    expect(audio.scan(reverse: false, speed: 6), isTrue);
    expect(audio.sample(drive), (588, -588));
    expect(audio.scan(reverse: true, speed: 0), isTrue);
    expect(audio.sample(drive), (597, -597));
    audio.pause();
    expect(audio.scanning, isFalse);
    expect(audio.sample(drive), (0, 0));
    audio.resume();
    expect(audio.sample(drive), (595, -595));
    expect(audio.sample(drive), (596, -596));
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

  test(
      'resume beyond the saved endpoint completes without an out-of-range read',
      () {
    final drive = cddaRampDrive(1);
    final audio = DcOpticalAudio()..start(150, 151, 0);
    audio.scan(reverse: false, speed: 10);
    for (var i = 0; i < 37; i++) {
      audio.sample(drive);
    }
    expect(audio.fad, 151);
    expect(audio.resume(), isTrue);
    expect(audio.status, 0x13);
    expect(audio.sample(drive), (0, 0));
    expect(drive.reads, [150]);
  });

  test('host cache misses preserve scan position and first unconsumed sample',
      () {
    final original = cddaRampDrive(2);
    final drive = _PendingDrive(original.sectors);
    final audio = DcOpticalAudio()..start(150, 151, 0);
    audio.scan(reverse: false, speed: 0);
    for (var i = 0; i < 1000; i++) {
      expect(audio.sample(drive), (0, 0));
    }
    expect(audio.fad, 150);
    drive.pending = false;
    expect(audio.sample(drive), (0, 0));
    expect(audio.sample(drive), (2, -2));
  });

  test(
      'reverse from lead-out retains position while the last sector is pending',
      () {
    final original = cddaRampDrive(2);
    final drive = _PendingDrive(original.sectors)..pending = false;
    final audio = DcOpticalAudio()..start(150, 151, 5);
    audio.scan(reverse: false, speed: 10);
    for (var i = 0; i < 74; i++) {
      audio.sample(drive);
    }
    expect(audio.fad, 152);
    drive.pending = true;
    audio.scan(reverse: true, speed: 10);
    for (var i = 0; i < 10; i++) {
      expect(audio.sample(drive), (0, 0));
    }
    expect(audio.fad, 152);
    expect(audio.repeatRemaining, 5);
    drive.pending = false;
    expect(audio.sample(drive), (1175, -1175));
    expect(audio.sample(drive), (1159, -1159));
  });

  test(
      'crossing between data and audio changes source handling in both directions',
      () {
    final original = cddaRampDrive(2);
    final drive =
        FakeCdromDrive(original.sectors, starts: [0, 1], audioTracks: {2});
    final audio = DcOpticalAudio()..start(150, 151, 0);
    audio.scan(reverse: false, speed: 0);
    for (var i = 0; i < 294; i++) {
      expect(audio.sample(drive), (0, 0));
    }
    expect(drive.reads, isEmpty);
    expect(audio.sample(drive), (588, -588));
    audio.scan(reverse: true, speed: 0);
    expect(audio.sample(drive), (590, -590));
    expect(audio.sample(drive), (588, -588));
    expect(audio.sample(drive), (0, 0));
    expect(drive.reads, [151]);
  });

  test('data-area scan moves silently without decoding sector data as audio',
      () {
    final drive = FakeCdromDrive(List.generate(3, (_) => Uint8List(1)));
    final audio = DcOpticalAudio()..start(150, 151, 0);
    audio.scan(reverse: false, speed: 10);
    for (var i = 0; i < 111; i++) {
      expect(audio.sample(drive), (0, 0));
    }
    expect(audio.fad, 153);
    expect(audio.status, 0x12);
    expect(drive.reads, isEmpty);
  });
}

class _PendingDrive extends FakeCdromDrive {
  _PendingDrive(super.sectors) : super(audioTracks: {1});
  bool pending = true;
  @override
  Uint8List? read(int lba) => pending ? null : super.read(lba);
}
