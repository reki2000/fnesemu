import 'dart:typed_data';

import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../core_module.dart';
import 'dc.dart';
import 'disc.dart';

CoreModule createModule() => DcModule();

class DcModule extends CoreModule {
  // .dc is reserved for flat development binaries; discs use content identity.
  static const system =
      CoreSystem('dc', 'dc', extensions: ['dc'], biosFiles: 2, disc: 'dc');

  @override
  List<CoreSystem> get systems => [system];
  @override
  Core create(String id) => Dc(
        bootBringUp:
            const bool.fromEnvironment('DC_BOOT_BRINGUP', defaultValue: true),
      );
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      mediaExtension(name) == 'dc' ? system : null;
  @override
  Future<CoreSystem?> identifyDisc(CdromDrive drive) async =>
      await isDcDisc(drive) ? system : null;
}
