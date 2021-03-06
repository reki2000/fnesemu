// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../../cpu/bus_debug.dart';
import '../../cpu/nes.dart';
import '../../styles.dart';

void showVram(BuildContext context, Nes emulator) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) {
        final vramDump = emulator.bus.debug(showVram: true);
        final charDump = emulator.bus.debug(showChar: true);
        const margin10 = EdgeInsets.all(10.0);
        return Scaffold(
          appBar: AppBar(title: const Text('VRAM')),
          body: Container(
            alignment: Alignment.center,
            // child: const Expanded(
            child: SingleChildScrollView(
                scrollDirection: Axis.vertical,
                child: Row(
                  children: [
                    Column(children: [
                      Container(
                          margin: margin10,
                          child: Text(vramDump, style: debugStyle))
                    ]),
                    Column(children: [
                      Container(
                          margin: margin10,
                          child: Text(charDump, style: debugStyle))
                    ]),
                  ],
                )),
          ),
        );
      },
    ),
  );
}
