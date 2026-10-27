import 'dart:typed_data';

import '../../core.dart';
import '../../core_module.dart';
import 'ps2.dart';

CoreModule createModule() => Ps2Module();

class Ps2Module extends CoreModule {
  static const system = CoreSystem('ps2', 'ps2',
      biosFiles: 1, biosRequired: false, extensions: ['elf']);
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 11;
  @override
  Core create(String id) => Ps2();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      system.extensions.contains(mediaExtension(name)) ? system : null;
}
