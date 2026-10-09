import 'dart:typed_data';
import '../core.dart';
import '../core_module.dart';
import 'snes.dart';

CoreModule createModule() => SnesModule();

class SnesModule extends CoreModule {
  static const system = CoreSystem('snes', 'snes', extensions: ['sfc', 'smc']);
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 7;
  @override
  Core create(String id) => Snes();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      system.extensions.contains(mediaExtension(name)) ? system : null;
}
