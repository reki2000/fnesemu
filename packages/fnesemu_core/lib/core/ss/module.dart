import 'dart:typed_data';

import '../cdrom.dart';
import '../cdrom_drive.dart';
import '../core.dart';
import '../core_module.dart';
import 'ss.dart';

CoreModule createModule() => SsModule();

class SsModule extends CoreModule {
  static const system =
      CoreSystem('ss', 'ss', biosFiles: 1, biosRequired: true, disc: 'ss');
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 4;
  @override
  int get discPriority => 10;
  @override
  Core create(String id) => Ss();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      system.extensions.contains(mediaExtension(name)) ? system : null;
  @override
  Future<CoreSystem?> identifyDisc(CdromDrive drive) async {
    final start = drive.firstDataLba;
    if (start == null) return null;
    return sectorContains(await drive.readWhenReady(start), 'SEGA SEGASATURN')
        ? system
        : null;
  }
}
