import 'package:fnesemu/core/md/md.dart';

import 'core.dart';
import 'nes/nes.dart';
import 'n64/n64.dart';
import 'pce/pce.dart';
import 'ps/ps.dart';

class CoreFactory {
  static Core ofPce() => Pce();
  static Core ofNes() => Nes();
  static Core ofMd() => Md();
  static Core ofN64() => N64();
  static Core ofPs() => Ps();

  static of(String coreName) {
    return switch (coreName) {
      'pce' => CoreFactory.ofPce(),
      'nes' => CoreFactory.ofNes(),
      'gen' || 'md' || "bin" => CoreFactory.ofMd(),
      'n64' || 'z64' || 'v64' => CoreFactory.ofN64(),
      'ps' => CoreFactory.ofPs(),
      _ => throw Exception('unsupported core: $coreName'),
    };
  }
}
