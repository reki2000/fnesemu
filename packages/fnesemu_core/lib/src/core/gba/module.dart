import 'dart:typed_data';
import '../core.dart';
import '../core_module.dart';
import 'gba.dart';

CoreModule createModule() => GbaModule();

class GbaModule extends CoreModule {
  static const system = CoreSystem('gba', 'gba',
      debugPaletteCount: 16, extensions: ['gba'], biosFiles: 1);
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 6;
  @override
  Core create(String id) => Gba();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      system.extensions.contains(mediaExtension(name)) ? system : null;
}
