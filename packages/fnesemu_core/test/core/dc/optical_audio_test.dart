import 'dart:typed_data';

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




  test('reset discards paused transport and its cached sector', () {
    final drive = FakeCdromDrive([sector(1, 2)], audioTracks: {1});
    final audio = DcOpticalAudio()..start(150, 151, 0);
    audio.sample(drive);
    audio.pause();
    audio.reset();
    expect(audio.resume(), isFalse);
    expect(audio.sample(drive), (0, 0));
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
