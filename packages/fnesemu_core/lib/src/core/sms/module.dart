import 'dart:typed_data';

import '../../core.dart';
import '../../core_module.dart';
import 'bus.dart';
import 'sms.dart';

CoreModule createModule() => SmsModule();

class SmsModule extends CoreModule {
  /// the console with the mode 4 VDP
  static const standard =
      CoreSystem('sms', 'sms', debugPaletteCount: 2, extensions: ['sms']);

  /// the domestic console with the FM sound chip
  static const mk3 = CoreSystem('mk3', 'sms', debugPaletteCount: 2);

  /// the earlier console with the TMS9918 VDP only
  static const tms = CoreSystem('smstms', 'sms', extensions: ['sg', 'sc']);

  /// the portable console with the 160x144 window and 12-bit colors
  static const portable =
      CoreSystem('smsport', 'sms', debugPaletteCount: 2, extensions: ['gg']);

  @override
  List<CoreSystem> get systems => [standard, mk3, tms, portable];
  @override
  int get order => 9;
  @override
  Core create(String id) => Sms(switch (id) {
        'smstms' => SmsModel.tms,
        'mk3' => SmsModel.mk3,
        'smsport' => SmsModel.portable,
        _ => SmsModel.standard,
      });
  @override
  CoreSystem? identifyRom(String name, Uint8List body) {
    final ext = mediaExtension(name);
    if (ext == 'sms') return _domestic(body) ? mk3 : standard;
    for (final system in systems) {
      if (system.extensions.contains(ext)) return system;
    }
    return null;
  }

  /// the header at 0x7ff0 starts with "TMR " and holds the region code in
  /// the high nibble of its last byte: 3 for the domestic console
  static bool _domestic(Uint8List body) =>
      body.length >= 0x8000 &&
      String.fromCharCodes(body.sublist(0x7ff0, 0x7ff4)) == 'TMR ' &&
      body[0x7fff] >> 4 == 3;
}
