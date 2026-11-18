import 'dart:typed_data';

import '../../cdrom.dart';
import '../../core.dart';
import '../../core_module.dart';
import '../../util/iso9660.dart';
import 'elf.dart';
import 'psp.dart';

CoreModule createModule() => PspModule();

class PspModule extends CoreModule {
  static const system =
      CoreSystem('psp', 'psp', disc: 'psp', extensions: ['elf', 'pbp']);
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 11;
  @override
  Core create(String id) => Psp();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) {
    if (!system.extensions.contains(mediaExtension(name))) return null;
    if (PspElf.isPbp(body)) return system;
    // An ELF belongs to this core only with its module info section; a
    // plain MIPS ELF falls through to the ps2 core.
    return PspElf.hasModuleInfo(body) ? system : null;
  }

  /// A disc of this core carries its boot executable in the game
  /// directory, as either the unencrypted or the encrypted boot file.
  @override
  Future<CoreSystem?> identifyDisc(CdromDrive drive) async {
    final start = drive.firstDataLba;
    if (start == null) return null;
    final iso = Iso9660(
        (lba) async => userData(await drive.readWhenReady(start + lba)));
    final boot = await iso.find('PSP_GAME/SYSDIR/BOOT.BIN') ??
        await iso.find('PSP_GAME/SYSDIR/EBOOT.BIN');
    return boot != null ? system : null;
  }
}
