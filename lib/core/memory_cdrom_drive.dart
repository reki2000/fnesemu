import 'dart:typed_data';

import 'cdrom_drive.dart';
import 'disc.dart';

/// [CdromDrive] backed by an on-memory [Disc].
///
/// Results are notified synchronously within [seek] and [read], so that it
/// works without an event loop (e.g. command line tests).
class MemoryCdromDrive implements CdromDrive {
  final Disc disc;
  final CdromToc _toc;
  int _headLba = 0;

  CdromDriveListener? _listener;

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

  @override
  set listener(CdromDriveListener? listener) => _listener = listener;

  @override
  CdromDriveStatus get status => CdromDriveStatus(
      disc.isEmpty ? CdromDriveState.empty : CdromDriveState.ready,
      _toc,
      _headLba,
      false);

  @override
  void seek(int lba) {
    _headLba = lba;
    _listener?.onSeekComplete(
        lba, !disc.isEmpty && lba >= 0 && lba < _toc.totalSectors);
  }

  @override
  void read(int lba) {
    _headLba = lba;
    final data = disc.isEmpty ? Uint8List(0) : disc.read(lba + 2 * 75);
    _listener?.onSectorRead(lba, data);
  }
}
