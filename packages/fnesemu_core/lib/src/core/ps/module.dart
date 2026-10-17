import 'dart:typed_data';

import '../../cdrom.dart';
import '../../cdrom_drive.dart';
import '../../core.dart';
import '../../core_module.dart';
import 'ps.dart';

CoreModule createModule() => PsModule();

// signature bytes, as character codes
const psLicenseSignature = '\x53\x6f\x6e\x79\x20\x43\x6f\x6d\x70\x75\x74\x65'
    '\x72\x20\x45\x6e\x74\x65\x72\x74\x61\x69\x6e\x6d'
    '\x65\x6e\x74';

// signature bytes, as character codes
const psSignature = '\x50\x4c\x41\x59\x53\x54\x41\x54\x49\x4f\x4e';

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
    if (sectorContains(
        await drive.readWhenReady(start + 4), psLicenseSignature)) {
      return system;
    }
    return sectorContains(await drive.readWhenReady(start + 16), psSignature)
        ? system
        : null;
  }
}
