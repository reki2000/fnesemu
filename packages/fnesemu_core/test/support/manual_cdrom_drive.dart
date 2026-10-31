import 'dart:typed_data';

import 'package:fnesemu_core/src/cdrom_drive.dart';

import 'fake_cdrom_drive.dart';

/// A manual lid with explicit host transitions and no guest-controlled eject.
class ManualCdromDrive extends FakeCdromDrive {
  ManualCdromDrive(this.generation,
      {this.state = CdromDriveState.ready, bool audio = false})
      : super([Uint8List(2352), Uint8List(2352)],
            audioTracks: audio ? {1} : {});

  int generation;
  CdromDriveState state;

  void change(CdromDriveState next, {bool emit = true}) {
    state = next;
    generation++;
    if (emit) events.add(next, generation);
  }

  @override
  CdromDriveStatus get status => CdromDriveStatus(
      state, generation, state == CdromDriveState.ready ? toc : CdromToc.empty);
}
