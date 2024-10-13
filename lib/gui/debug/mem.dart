// Dart imports:
// Flutter imports:
import 'package:flutter/material.dart';

import '../../core/core_controller.dart';
// Project imports:
import '../../styles.dart';
import '../../util/util.dart';

Widget _dump(CoreController controller, int start) {
  final lines = <String>[];
  for (var i = 0; i < 64; i++) {
    String line = "${hex16((start + i * 16) & 0xffff)}: ";
    for (var j = 0; j < 16; j++) {
      final addr = (start + i * 16 + j) & 0xffff;
      line += "${hex8(controller.debugger.read(addr))} ";
    }
    lines.add(line);
  }

  return Text(lines.join('\n'), style: debugStyle);
}

void pushMemPage(BuildContext context, CoreController controller) {
  final addrNotifier = ValueNotifier<int>(0);

  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) {
        return Scaffold(
          appBar: AppBar(title: const Text('Mem')),
          body: Container(
            alignment: Alignment.center,
            margin: const EdgeInsets.all(10.0),
            child: Column(children: [
              ValueListenableBuilder<int>(
                  valueListenable: addrNotifier,
                  builder: (context, addr, child) => _dump(controller, addr)),
              Row(children: [
                SizedBox(
                    width: 50,
                    child: TextField(onChanged: (v) {
                      if (v.length == 4) {
                        addrNotifier.value = int.parse(v, radix: 16);
                      }
                    })),
                ElevatedButton(
                    child: const Text("-"),
                    onPressed: () => addrNotifier.value =
                        (addrNotifier.value - 0x400) & 0xffff),
                ElevatedButton(
                    child: const Text("+"),
                    onPressed: () => addrNotifier.value += 0x400),
              ]),
            ]),
          ),
        );
      },
    ),
  );
}
