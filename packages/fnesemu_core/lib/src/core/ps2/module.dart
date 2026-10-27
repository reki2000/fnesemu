import 'dart:convert';
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
    final start = drive.firstDataLba;
    if (start == null) return null;
    final iso = Iso9660(
        (lba) async => userData(await drive.readWhenReady(start + lba)));
    final file = await iso.findRootFile('SYSTEM.CNF');
    if (file == null) return null;
    final text = utf8.decode(await iso.readFile(file), allowMalformed: true);
    return text.contains('BOOT2') ? system : null;
  }
}

/// The 2048 bytes of user data in a raw sector (mode 1 or mode 2 form 1).
Uint8List userData(Uint8List raw) {
  if (raw.length < 2352) return Uint8List(0);
  final offset = raw[15] == 2 ? 24 : 16;
  return Uint8List.sublistView(raw, offset, offset + 2048);
}
