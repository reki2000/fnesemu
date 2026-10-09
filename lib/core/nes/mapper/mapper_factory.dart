import 'cnrom.dart';
import 'fme7.dart';
import 'mapper.dart';
import 'mapper088.dart';
import 'mmc1.dart';
import 'mmc2.dart';
import 'mmc3.dart';
import 'mmc4.dart';
import 'mmc5.dart';
import 'namco118.dart';
import 'namco163.dart';
import 'nrom.dart';
import 'uxrom.dart';
import 'vrc1.dart';
import 'vrc3.dart';
import 'vrc4.dart';
import 'vrc6.dart';
import 'vrc7.dart';

/// Constructs cartridge mappers without coupling their base class to implementations.
class MapperFactory {
  static Mapper of(int iNesMapper) {
    return switch (iNesMapper) {
      0 => MapperNROM(),
      1 => MapperMMC1(),
      2 => MapperUxROM(),
      3 => MapperCNROM(),
      4 => MapperMMC3(),
      9 => MapperMMC2(),
      10 => MapperMMC4(),
      5 => MapperMmc5(),
      75 => MapperVrc1(),
      21 => MapperVrc4a4c(),
      23 => MapperVrc4f4e(),
      25 => MapperVrc4b4d(),
      24 => MapperVrc6a(),
      26 => MapperVrc6b(),
      85 => MapperVrc7(),
      19 => MapperNamco163(),
      73 => MapperVrc3(),
      88 => Mapper088(),
      118 => MapperTxsrom(),
      206 => MapperNamco118(),
      69 => MapperFme7(),
      _ => throw Exception("unimplemented mapper:$iNesMapper!")
    };
  }
}
