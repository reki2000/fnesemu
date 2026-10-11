import 'dart:typed_data';

import '../../cdrom.dart';
import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../core_module.dart';
import 'ps.dart';

CoreModule createModule() => PsModule();

class PsModule extends CoreModule {
  static const system = CoreSystem('ps', 'ps1',
      biosFiles: 1, biosRequired: true, disc: 'ps', extensions: ['exe']);
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 3;
  @override
  int get discPriority => 20;
  @override
  Core create(String id) => Ps();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      system.extensions.contains(mediaExtension(name)) ? system : null;
  @override
  Future<CoreSystem?> identifyDisc(CdromDrive drive) async {
    final start = drive.firstDataLba;
    if (start == null) return null;
    return sectorContains(await drive.readWhenReady(start + 4),
                'Sony Computer Entertainment') ||
            sectorContains(await drive.readWhenReady(start + 16), 'PLAYSTATION')
        ? system
        : null;
  }
}
