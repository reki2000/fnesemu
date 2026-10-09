import 'dart:typed_data';

import 'package:fnesemu_core/util/int.dart';

import 'cdrom_drive.dart';

/// The disc in a [CdromDrive], as seen by the CD cores.
///
/// [read] returns null while the drive is still reading the sector in the
/// background: the core retries it later.
class Disc {
  final CdromDrive drive;

  Disc(this.drive);

  Disc.empty() : drive = EmptyCdromDrive();

  CdromToc get toc => drive.status.toc;

  bool get isEmpty => !drive.status.isReady;
  int get trackCount => toc.trackCount;
  int get totalSectors => toc.totalSectors;
  int startLba(int trackNo) => toc.startLba(trackNo);
  bool isAudio(int trackNo) => toc.isAudio(trackNo);

  /// [sector] is an absolute MSF sector, including the lead-in. returns an
  /// empty list if it is not readable, null if it is not read yet.
  Uint8List? read(int sector) => drive.read(sector - 150);

  // Like read(), sector is an absolute MSF sector, including the lead-in.
  bool isAudioSector(int sector) {
    sector -= 150;
    if (isEmpty) return false;
    if (sector < 0 || sector >= totalSectors) return false;
    return toc.isAudioLba(sector);
  }

  static const int sectorSize = 2352; // 0x930 = 24bytes x 98frames
  // static const int sectorDataSize = 2324; // bytes per sector data
  /// Expand a cooked Mode 1 sector to the raw format used by the CD cores.
  /// EDC/ECC bytes remain zero; the emulator does not perform error correction.
  static Uint8List mode1Sector(Uint8List data, int lba) {
    if (data.length != 2048) {
      throw ArgumentError('Mode 1 data must be 2048 bytes');
    }
    final sector = Uint8List(sectorSize)..setAll(0, sync);
    final (m, s, f) = lbaToMsf(lba, addLeadIn: true);
    int bcd(int value) => ((value ~/ 10) << 4) | (value % 10);
    sector.setAll(12, [bcd(m), bcd(s), bcd(f), 1]);
    sector.setAll(16, data);
    return sector;
  }

  static Uint8List emptySector = Uint8List(sectorSize);

  static const sync = [
    0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0 // 12 bytes
  ];

  static String dumpSector(int sector) {
    final (m, s, f) = lbaToMsf(sector);
    final mm = m.d2z;
    final ss = s.d2z;
    final ff = f.d2z;
    return "$sector ($mm:$ss:$ff)";
  }

  static (int, int, int) lbaToMsf(int lba, {bool addLeadIn = false}) {
    final msf = lba + (addLeadIn ? 150 : 0);
    final m = msf ~/ (60 * 75);
    final s = (msf ~/ 75) % 60;
    final f = msf % 75;
    return (m, s, f);
  }
}
