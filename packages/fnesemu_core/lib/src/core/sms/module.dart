import 'dart:typed_data';

import '../../core.dart';
import '../../core_module.dart';
import 'bus.dart';
import 'sms.dart';

CoreModule createModule() => SmsModule();

class SmsModule extends CoreModule {
  static const sg1000 =
      CoreSystem('sg1000', 'sg1000', extensions: ['sg', 'sc']);
  static const sms =
      CoreSystem('sms', 'sms', debugPaletteCount: 2, extensions: ['sms']);
  static const gg =
      CoreSystem('gg', 'gg', debugPaletteCount: 2, extensions: ['gg']);
  @override
  List<CoreSystem> get systems => [sg1000, sms, gg];
  @override
  int get order => 9;
  @override
  Core create(String id) => Sms(switch (id) {
        'sg1000' => SmsModel.sg1000,
        'gg' => SmsModel.gg,
        _ => SmsModel.sms,
      });
  @override
  CoreSystem? identifyRom(String name, Uint8List body) {
    final ext = mediaExtension(name);
    for (final system in systems) {
      if (system.extensions.contains(ext)) return system;
    }
    return null;
  }
}
