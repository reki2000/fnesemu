// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:package_info_plus/package_info_plus.dart';

// Project imports:
import 'gui/gui.dart';

void main() {
  runApp(
    FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          switch (snapshot.connectionState) {
            case ConnectionState.done:
              return MyApp(title: "fnesemu ${snapshot.data!.version}");
            default:
              return const SizedBox();
          }
        }),
  );
}
