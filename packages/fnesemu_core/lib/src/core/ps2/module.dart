import 'dart:typed_data';

import '../../cdrom.dart';
import '../../core.dart';
import '../../core_module.dart';
import 'iso9660.dart';
import 'ps2.dart';

CoreModule createModule() => Ps2Module();

class Ps2Module extends CoreModule {
  static const system = CoreSystem('ps2', 'ps2',
      biosFiles: 1, biosRequired: false, disc: 'ps2', extensions: ['elf']);
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 11;

  /// PS2 discs also carry the PS1 signature text, so they are checked first.
  @override
  int get discPriority => 15;
  @override
  Core create(String id) => Ps2();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      system.extensions.contains(mediaExtension(name)) ? system : null;
  @override
  Future<CoreSystem?> identifyDisc(CdromDrive drive) async {
    final text = await readSystemCnf(drive);
    return text != null && text.contains('BOOT2') ? system : null;
  }
}
