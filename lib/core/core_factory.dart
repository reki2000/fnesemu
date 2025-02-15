import 'package:fnesemu/core/md/md.dart';

import 'core.dart';
import 'nes/nes.dart';
import 'pce/pce.dart';

class CoreFactory {
  static Core ofPce() {
    return Pce();
  }

  static Core ofNes() {
    return Nes();
  }

  static Core ofMd() {
    return Md();
  }

  static of(String coreName) {
    return switch (coreName) {
      'pce' => CoreFactory.ofPce(),
      'nes' => CoreFactory.ofNes(),
      'gen' || 'md' => CoreFactory.ofMd(),
      _ => throw Exception('unsupported core: $coreName'),
    };
  }
}
