import 'dart:typed_data';
import '../core.dart';
import '../core_module.dart';
import 'gb.dart';

CoreModule createModule() => GbModule();

class GbModule extends CoreModule {
  static const system =
      CoreSystem('gb', 'gb', debugPaletteCount: 4, extensions: ['gb']);
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 5;
  @override
  Core create(String id) => Gb();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      system.extensions.contains(mediaExtension(name)) ? system : null;
}
