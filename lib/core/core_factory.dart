import 'package:fnesemu/core/md/md.dart';

import 'core.dart';
import 'nes/nes.dart';
import 'pce/pce.dart';
import 'ps/ps.dart';
import 'ss/ss.dart';

class CoreFactory {
  static Core ofPce() => Pce();
  static Core ofNes() => Nes();
  static Core ofMd() => Md();
  static Core ofPs() => Ps();
  static Core ofSs() => Ss();

  static of(String coreName) {
    return switch (coreName) {
      'pce' => CoreFactory.ofPce(),
      'nes' => CoreFactory.ofNes(),
      'gen' || 'md' || "bin" => CoreFactory.ofMd(),
      'ps' => CoreFactory.ofPs(),
      'ss' => CoreFactory.ofSs(),
      _ => throw Exception('unsupported core: $coreName'),
    };
  }
}
