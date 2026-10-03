import 'dart:typed_data';

import 'cdrom_drive.dart';
import 'disc.dart';

/// [CdromDrive] backed by an on-memory [Disc]. all sectors are always
/// available.
class MemoryCdromDrive implements CdromDrive {
  final Disc disc;
  final CdromToc _toc;
  late CdromDriveStatus _status = _statusOf(0, false);

  MemoryCdromDrive(this.disc) : _toc = _tocOf(disc);

  static CdromToc _tocOf(Disc disc) {
    if (disc.isEmpty) {
      return CdromToc.empty;
    }
    final tracks = <CdromTrack>[];
    for (int no = 1; no <= disc.trackCount; no++) {
      final start = disc.startLba(no);
      final end =
          no < disc.trackCount ? disc.startLba(no + 1) : disc.totalSectors;
      tracks.add(CdromTrack(no, disc.isAudio(no), start, end - start));
    }
    return CdromToc(tracks, disc.totalSectors);
  }

  bool _isReadable(int lba) =>
      !disc.isEmpty && lba >= 0 && lba < _toc.totalSectors;

  CdromDriveStatus _statusOf(int seekLba, bool seekError) => CdromDriveStatus(
      disc.isEmpty ? CdromDriveState.empty : CdromDriveState.ready, 1, _toc,
      seekLba: seekLba, seekError: seekError);

  @override
  CdromDriveStatus get status => _status;

  @override
  void seek(int lba) => _status = _statusOf(lba, !_isReadable(lba));

  @override
  Uint8List? read(int lba) =>
      _isReadable(lba) ? disc.read(lba + 2 * 75) : Uint8List(0);
}
