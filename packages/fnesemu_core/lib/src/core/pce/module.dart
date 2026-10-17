import 'dart:typed_data';

import '../../cdrom.dart';
import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../core_module.dart';
import 'pce.dart';

CoreModule createModule() => PceModule();

// signature bytes, as character codes
const pceCdSignature = '\x50\x43\x20\x45\x6e\x67\x69\x6e\x65\x20\x43\x44'
    '\x2d\x52\x4f\x4d\x20\x53\x59\x53\x54\x45\x4d';

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
  Future<CoreSystem?> identifyDisc(CdromDrive drive) async {
    final start = drive.firstDataLba;
    if (start == null) return null;
    for (final lba in [start + 1, start, start + 2, start + 3]) {
      if (sectorContains(await drive.readWhenReady(lba), pceCdSignature)) {
        return cd;
      }
    }
    return null;
  }
}
