import 'dart:typed_data';

import 'package:cdrom/cdrom.dart';
import 'package:fnesemu_core/core/core_api.dart';
import 'package:fnesemu_core/util/debug.dart';

/// the [CdromDrive] of the cores, which reads a disc image by a [DiscDrive]
/// of the cdrom package
class AsyncCdromDrive implements CdromDrive {
  final DiscDrive drive;

  AsyncCdromDrive({DateTime Function()? now})
      : drive = DiscDrive(now: now, log: debugLog);

  DiscDriveStatus? _from;
  CdromDriveStatus _status = CdromDriveStatus.empty;
  DiscToc? _fromToc;
  CdromToc _toc = CdromToc.empty;

  /// converted only when the status of [drive] changes, as the core polls it
  /// on each exec
  @override
  CdromDriveStatus get status {
    final s = drive.status;
    if (!identical(s, _from)) {
      _from = s;
      if (!identical(s.toc, _fromToc)) {
        _fromToc = s.toc;
        _toc = CdromToc([
          for (final t in s.toc.tracks)
            CdromTrack(t.number, t.isAudio, t.startLba, t.sectors)
        ], s.toc.totalSectors);
      }
      _status = CdromDriveStatus(
          CdromDriveState.values.byName(s.state.name), s.discId, _toc,
          seekLba: s.seekLba, isSeeking: s.isSeeking, seekError: s.seekError);
    }
    return _status;
  }

  @override
  void seek(int lba) => drive.seek(lba);

  @override
  Uint8List? read(int lba) => drive.read(lba);

  /// see [DiscDrive.insert]
  Future<void> insert([DiscSource? source]) => drive.insert(source);

  /// see [DiscDrive.eject]
  Future<void> eject() => drive.eject();

  /// see [DiscDrive.settle]
  Future<void> settle() => drive.settle();
}
