// Dart imports:
// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../../styles.dart';
import '../../util.dart';
import '../core_controller.dart';

Widget _dump(List<int> buf, int start) {
  final lines = <String>[];
  for (var i = 0; i < 64; i++) {
    final addr = (start + i * 16) & 0xffff;
    final lineData = buf.sublist(addr, addr + 16);
    final line = "${hex16(addr)}: ${lineData.map((e) => hex16(e)).join(' ')}";
    lines.add(line);
  }

  return Text(lines.join('\n'), style: debugStyle);
}

void pushVramPage(BuildContext context, CoreController controller) {
  final addrNotifier = ValueNotifier<int>(0);

  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) {
        return Scaffold(
          appBar: AppBar(title: const Text('VRAM')),
          body: Container(
            alignment: Alignment.center,
            margin: const EdgeInsets.all(10.0),
            child: Column(children: [
              ValueListenableBuilder<int>(
                  valueListenable: addrNotifier,
                  builder: (context, addr, child) =>
                      _dump(controller.debugger.dumpVram(), addr)),
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
