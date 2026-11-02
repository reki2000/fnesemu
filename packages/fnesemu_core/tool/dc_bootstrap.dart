import 'package:fnesemu_core/src/core/dc/disc_bootstrap.dart' as dc;

import 'cdrom_drive.dart';

export 'package:fnesemu_core/src/core/dc/disc_bootstrap.dart' show DcBootstrap;

/// Tool adapter; ISO interpretation belongs to the DC core.
Future<dc.DcBootstrap> loadDcBootstrap(SimpleCdromDrive drive) =>
    dc.loadDcBootstrap(drive, waitForSector: drive.settle);
