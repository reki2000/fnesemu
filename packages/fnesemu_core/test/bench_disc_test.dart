import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:test/test.dart';

void main() {
  test('encodes and decodes TOC, sectors and subcodes', () {
    final sector0 = Uint8List.fromList(List.generate(2352, (i) => i & 0xff));
    final rawSub = Uint8List.fromList(List.generate(96, (i) => (i * 3) & 0xff));
    final disc = BenchDisc(
      const CdromToc(
        [
          CdromTrack(1, false, 0, 1000),
          CdromTrack(2, true, 1000, 500),
        ],
        1500,
        sessions: [
          CdromSession(1, 1, 0),
          CdromSession(2, 2, 1000),
        ],
        isXa: true,
        medium: CdromMedium.gd,
      ),
      {
        16: sector0,
        99: Uint8List(0),
      },
      subcodes: {
        16: CdromSubcode.fromRaw(rawSub),
        17: const CdromSubcode(),
        18: const CdromSubcode(readable: false),
      },
      hasSubcodes: true,
    );

    final decoded = BenchDisc.decode(disc.encode());
    expect(decoded.toc.totalSectors, 1500);
    expect(decoded.toc.medium, CdromMedium.gd);
    expect(decoded.toc.isXa, isTrue);
    expect(decoded.toc.tracks, hasLength(2));
    expect((decoded.toc.tracks[0].number, decoded.toc.tracks[0].isAudio),
        (1, false));
    expect((decoded.toc.tracks[1].startLba, decoded.toc.tracks[1].sectors),
        (1000, 500));
    expect(decoded.toc.sessions, hasLength(2));
    expect(decoded.toc.sessions![1].startLba, 1000);
    expect(decoded.hasSubcodes, isTrue);

    final drive = decoded.openDrive();
    expect(drive.status.isReady, isTrue);
    expect(drive.read(16), sector0);
    expect(drive.read(99), isEmpty);
    expect(drive.read(50)?.length, 2352);
    expect(drive.read(1500), isEmpty);

    drive.seek(16);
    expect(
        (drive.status.seekLba, drive.status.isSeeking, drive.status.seekError),
        (16, false, false));
    drive.seek(99);
    expect(drive.status.seekError, isTrue);
    drive.seek(1500);
    expect(drive.status.seekError, isTrue);

    expect(drive.readSubcode(16)?.raw, rawSub);
    expect(drive.readSubcode(17)?.readable, isTrue);
    expect(drive.readSubcode(17)?.raw, isNull);
    expect(drive.readSubcode(18)?.readable, isFalse);
    expect(drive.readSubcode(1500)?.readable, isFalse);
  });

  test('rejects invalid bench disc headers', () {
    expect(() => BenchDisc.decode(Uint8List(4)), throwsFormatException);
    expect(() => BenchDisc.decode(Uint8List(32)), throwsFormatException);
  });
}
