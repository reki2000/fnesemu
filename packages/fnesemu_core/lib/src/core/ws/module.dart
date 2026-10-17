import 'dart:typed_data';

import '../../core.dart';
import '../../core_module.dart';
import 'ws.dart';

CoreModule createModule() => WsModule();

class WsModule extends CoreModule {
  static const mono = CoreSystem('ws', 'ws', extensions: ['ws']);
  static const color =
      CoreSystem('wsc', 'wsc', debugPaletteCount: 16, extensions: ['wsc']);
  @override
  List<CoreSystem> get systems => [mono, color];
  @override
  int get order => 10;
  @override
  Core create(String id) => Ws(color: id == color.id);
  @override
  CoreSystem? identifyRom(String name, Uint8List body) =>
      switch (mediaExtension(name)) {
        'wsc' => color,
        // color games are run on the WonderSwan Color
        'ws' =>
          body.length >= 16 && body[body.length - 9] & 1 != 0 ? color : mono,
        _ => null,
      };
}
