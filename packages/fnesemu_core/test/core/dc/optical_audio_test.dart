import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/optical_audio.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';

void main() {
  Uint8List sector(int left, int right) {
    final bytes = ByteData(2352);
    for (var i = 0; i < 588; i++) {
      bytes.setInt16(i * 4, left, Endian.little);
      bytes.setInt16(i * 4 + 2, right, Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  test('stereo signed frames, exact sector boundary and exclusive endpoint',
      () {
    final drive = FakeCdromDrive([sector(-32768, 32767), sector(123, -456)],
        audioTracks: {1});
    final audio = DcOpticalAudio()..start(150, 152, 0);
    for (var i = 0; i < 588; i++) {
      expect(audio.sample(drive), (-32768, 32767));
    }
    expect(audio.fad, 151);
    expect(drive.reads, [150]);
    for (var i = 0; i < 588; i++) {
      expect(audio.sample(drive), (123, -456));
    }
    expect(audio.fad, 152);
    expect(audio.playing, isFalse);
    expect(audio.resume(), isFalse);
    expect(audio.sample(drive), (0, 0));
    expect(drive.reads, [150, 151]);
  });

  test('pause preserves the exact next sample and repeat range', () {
    final raw = sector(0, 0)..[4] = 77;
    final drive = FakeCdromDrive([raw, sector(0, 0)], audioTracks: {1});
    final audio = DcOpticalAudio()..start(150, 151, 1);
    expect(audio.sample(drive), (0, 0));
    audio.pause();
    expect(audio.sample(drive), (0, 0));
    expect(audio.resume(), isTrue);
    expect(audio.sample(drive), (77, 0));
    for (var i = 2; i < 1176; i++) {
      audio.sample(drive);
    }
    expect(audio.playing, isFalse);
    expect(drive.reads, [150, 150]);
  });

  test('physical lead-out overrides endless repeat', () {
    final drive = FakeCdromDrive([sector(1, 2)], audioTracks: {1});
    final audio = DcOpticalAudio()..start(150, 151, 15);
    for (var i = 0; i < 588; i++) {
      audio.sample(drive);
    }
    expect(audio.playing, isFalse);
    expect(drive.reads, [150]);
  });

  test('data tracks advance silently without interpreting sector headers', () {
    final drive = FakeCdromDrive([Uint8List(1)]);
    final audio = DcOpticalAudio()..start(150, 151, 0);
    for (var i = 0; i < 588; i++) {
      expect(audio.sample(drive), (0, 0));
    }
    expect(audio.playing, isFalse);
    expect(drive.reads, isEmpty);
  });

  test('reset discards paused transport and its cached sector', () {
    final drive = FakeCdromDrive([sector(1, 2)], audioTracks: {1});
    final audio = DcOpticalAudio()..start(150, 151, 0);
    audio.sample(drive);
    audio.pause();
    audio.reset();
    expect(audio.resume(), isFalse);
    expect(audio.sample(drive), (0, 0));
  });
  test('host cache misses preserve position and retry without dropping a frame',
      () {
    final drive = _PendingDrive([sector(123, -456)]);
    final audio = DcOpticalAudio()..start(150, 151, 0);
    for (var i = 0; i < 1000; i++) {
      expect(audio.sample(drive), (0, 0));
    }
    expect(audio.fad, 150);
    drive.pending = false;
    for (var i = 0; i < 588; i++) {
      expect(audio.sample(drive), (123, -456));
    }
    expect(audio.playing, isFalse);
  });

  test('endless range repeats before lead-out and rereads changed sectors', () {
    final drive =
        FakeCdromDrive([sector(1, 2), sector(3, 4)], audioTracks: {1});
    final audio = DcOpticalAudio()..start(150, 151, 15);
    for (var i = 0; i < 588; i++) {
      audio.sample(drive);
    }
    expect(audio.playing, isTrue);
    drive.sectors[0] = sector(5, 6);
    expect(audio.sample(drive), (5, 6));
  });

  test('invalid raw sectors stop explicitly without consuming source position',
      () {
    final drive = FakeCdromDrive([Uint8List(0)], audioTracks: {1});
    final audio = DcOpticalAudio()..start(150, 151, 0);
    expect(() => audio.sample(drive), throwsA(isA<DcUnsupported>()));
    expect(audio.fad, 150);
    drive.sectors[0] = sector(7, 8);
    expect(audio.sample(drive), (7, 8));
  });
  test('playback errors report once and reset clears the retained result', () {
    final audio = DcOpticalAudio()..start(150, 151, 0);
    expect(audio.status, 0x11);
    audio.fail();
    expect(audio.playing, isFalse);
    expect(audio.resume(), isFalse);
    expect(audio.status, 0x14);
    expect(audio.takeStatus(), 0x14);
    expect(audio.takeStatus(), 0x15);
    audio.fail();
    audio.reset();
    expect(audio.takeStatus(), 0x15);
  });
}

class _PendingDrive extends FakeCdromDrive {
  _PendingDrive(super.sectors) : super(audioTracks: {1});
  bool pending = true;
  @override
  Uint8List? read(int lba) => pending ? null : super.read(lba);
}
