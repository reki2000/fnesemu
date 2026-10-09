import 'dart:typed_data';

import '../cdrom_drive.dart';
import '../core.dart';
import '../core_module.dart';
import '../media_input.dart';
import 'pce.dart';

CoreModule createModule() => PceModule();

class PceModule extends CoreModule {
  static const cartridge = CoreSystem('pce', 'pce',
      debugPaletteCount: 32,
      debugVramBits: 16,
      extensions: ['pce'],
      disc: 'pcecd');
  static const cd = CoreSystem('pcecd', 'pce',
      debugPaletteCount: 32,
      debugVramBits: 16,
      biosFiles: 1,
      biosRequired: true,
      disc: 'pcecd');
  @override
  List<CoreSystem> get systems => [cartridge, cd];
  @override
  int get order => 1;
  @override
  int get discPriority => 30;
  @override
  Core create(String id) => Pce();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      mediaExtension(name) == 'pce' ? cartridge : null;
  @override
  MediaHint mediaHint(String name) => switch (mediaExtension(name)) {
        'cue' || 'iso' => MediaHint.disc,
        'bin' => MediaHint.ambiguous,
        _ => MediaHint.unknown,
      };
  @override
  Future<CoreSystem?> identifyDisc(CdromDrive drive) async {
    final start = firstDataLba(drive);
    if (start == null) return null;
    for (final lba in [start + 1, start, start + 2, start + 3]) {
      if (sectorContains(
          await readDiscSector(drive, lba), 'PC Engine CD-ROM SYSTEM')) {
        return cd;
      }
    }
    return null;
  }
}
