import 'dart:typed_data';

import '../../core.dart';
import '../../core_module.dart';
import 'elf.dart';
import 'psp.dart';

CoreModule createModule() => PspModule();

class PspModule extends CoreModule {
  static const system = CoreSystem('psp', 'psp', extensions: ['elf', 'pbp']);
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
}
