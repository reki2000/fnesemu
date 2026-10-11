import 'dart:typed_data';
import '../../core.dart';
import '../../core_module.dart';
import 'n64.dart';

CoreModule createModule() => N64Module();

class N64Module extends CoreModule {
  static const system =
      CoreSystem('n64', 'n64', extensions: ['n64', 'z64', 'v64']);
  @override
  List<CoreSystem> get systems => [system];
  @override
  int get order => 8;
  @override
  Core create(String id) => N64();
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      system.extensions.contains(mediaExtension(name)) ? system : null;
}
