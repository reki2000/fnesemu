import 'package:flutter/material.dart';

import '../../core/core_api.dart';
import '../../styles.dart';

Widget _dump(List<int> buf, int start, int bits) {
  final lines = <String>[];
  for (var i = 0; i < 32; i++) {
    final addr = start + i * 16;
    if (addr >= buf.length) break;
    final end = (addr + 16).clamp(0, buf.length);
    final lineData = buf.sublist(addr, end);
    final addressDigits = ((buf.length - 1).bitLength + 3) ~/ 4;
    final line = '${addr.toRadixString(16).padLeft(addressDigits, "0")}: '
        '${lineData.map((word) => word.toRadixString(16).padLeft((bits + 3) ~/ 4, "0")).join(" ")}';
    lines.add(line);
  }

  return Text(lines.join('\n'), style: debugStyle);
}

void pushVramPage(BuildContext context, CoreController controller) {
  final addrNotifier = ValueNotifier<int>(0);
  void jump(int value) {
    final length = controller.debugger.dumpVram().length;
    addrNotifier.value = value.clamp(0, length > 0 ? length - 1 : 0);
  }

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
                  builder: (context, addr, child) => _dump(
                      controller.debugger.dumpVram(),
                      addr,
                      controller.debugger.vramBits)),
              Row(children: [
                SizedBox(
                    width: 50,
                    child: TextField(onChanged: (v) {
                      final value = int.tryParse(v, radix: 16);
                      if (value != null) jump(value);
                    })),
                ElevatedButton(
                    child: const Text("-"),
                    onPressed: () => jump(addrNotifier.value - 0x400)),
                ElevatedButton(
                    child: const Text("+"),
                    onPressed: () => jump(addrNotifier.value + 0x400)),
              ]),
            ]),
          ),
        );
      },
    ),
  );
}
