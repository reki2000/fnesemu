import 'package:fnesemu/core/md/md.dart';

import 'core.dart';
import 'gb/gb.dart';
import 'gba/gba.dart';
import 'nes/nes.dart';
import 'pce/pce.dart';
import 'ps/ps.dart';
import 'ss/ss.dart';

class CoreFactory {
  static Core ofPce() => Pce();
  static Core ofNes() => Nes();
  static Core ofMd() => Md();
  static Core ofPs() => Ps();
  static Core ofGb() => Gb();
  static Core ofSs() => Ss();
  static Core ofGba() => Gba();

  static of(String coreName) {
    return switch (coreName) {
      'pce' => CoreFactory.ofPce(),
      'nes' => CoreFactory.ofNes(),
      'gen' || 'md' || "bin" => CoreFactory.ofMd(),
      'ps' => CoreFactory.ofPs(),
      'gb' => CoreFactory.ofGb(),
      'ss' => CoreFactory.ofSs(),
      'gba' => CoreFactory.ofGba(),
      _ => throw Exception('unsupported core: $coreName'),
    };
  }
}
