import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/cdrom_drive.dart';
import 'package:fnesemu_core/src/core/md/module.dart';
import 'package:fnesemu_core/src/core/pce/module.dart';
import 'package:fnesemu_core/src/core/ps/module.dart';
import 'package:fnesemu_core/src/core/ss/module.dart';
import 'package:test/test.dart';

/// a ready drive whose sectors are filled with zero except [sectors]
class _Drive implements CdromDrive {
  final List<CdromTrack> tracks;
  final Map<int, String> sectors;

  _Drive(this.tracks, this.sectors);

  @override
  CdromDriveStatus get status =>
      CdromDriveStatus(CdromDriveState.ready, 1, CdromToc(tracks, 100000));

  @override
  CdromDriveEvent? takeEvent() => null;

  @override
  void clearEvents() {}

  @override
  void seek(int lba) {}

  @override
  Uint8List? read(int lba) {
    final sector = Uint8List(2352);
    final s = sectors[lba];
    if (s != null) sector.setAll(16, s.codeUnits);
    return sector;
  }
}

void main() {
  const data = CdromTrack(1, false, 0, 50000);

  test('every system has its core', () {
    for (final s in CoreFactory.systems) {
      final core = CoreFactory.of(s.id);
      addTearDown(core.dispose);
      expect(core, isNotNull, reason: s.id);
      expect(core.clocksPerFrame, greaterThan(0), reason: s.id);
      expect(core.clocksPerFrame, core.clocksInScanline * core.scanlinesInFrame,
          reason: s.id);
    }
  });

}
