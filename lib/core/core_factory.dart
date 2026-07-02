import 'package:fnesemu/core/md/md.dart';

import 'core.dart';
import 'nes/nes.dart';
import 'pce/pce.dart';
import 'ps/ps.dart';
import 'snes/snes.dart';

class CoreFactory {
  static Core ofPce() => Pce();
  static Core ofNes() => Nes();
  static Core ofMd() => Md();
  static Core ofPs() => Ps();
  static Core ofSnes() => Snes();

  static of(String coreName) {
    return switch (coreName) {
      'pce' => CoreFactory.ofPce(),
      'nes' => CoreFactory.ofNes(),
      'gen' || 'md' || "bin" => CoreFactory.ofMd(),
      'ps' => CoreFactory.ofPs(),
      'sfc' || 'smc' => CoreFactory.ofSnes(),
      _ => throw Exception('unsupported core: $coreName'),
    };
  }
}
