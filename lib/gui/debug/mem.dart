// Dart imports:
// Flutter imports:
import 'package:flutter/material.dart';
import 'package:fnesemu/util/int.dart';

// Project imports:
import '../../core/debugger.dart';
import '../../styles.dart';

const _addrBitSize = 24;
const _mask = (1 << _addrBitSize) - 1;

const _addrTextLength = _addrBitSize >> 2;

const _addrIncSize = 0x200;
const _bytesPerLine = 16; //22; // 22 for exodus view

String _dump(Debugger debugger, int start) {
  final lines = <String>[];

  for (int base = start; base < start + _addrIncSize; base += _bytesPerLine) {
    final bytes = List.generate(
        _bytesPerLine, (i) => debugger.read((base + i) & _mask).hex8);
    lines.add("${base.hex24}: ${bytes.join(" ")}");
  }

  return lines.join("\n");
}

class MemPane extends StatelessWidget {
  final Debugger debugger;
  final addrNotifier = ValueNotifier<int>(0);

  MemPane({super.key, required this.debugger}) {
    addrNotifier.value = debugger.opt.memAddress;
  }

  int get _addr => addrNotifier.value;
  set _addr(int addr) {
    final masked = addr & _mask;
    debugger.opt.memAddress = masked;
    addrNotifier.value = masked;
  }

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.topLeft,
        margin: const EdgeInsets.all(10.0),
        child: Column(children: [
          Row(children: [
            SizedBox(
                width: 80,
                child: TextField(
                    controller: TextEditingController(
                        text: _addr
                            .toRadixString(16)
                            .padLeft(_addrTextLength, '0')),
                    onChanged: (v) {
                      if (v.isNotEmpty && v.length == _addrTextLength) {
                        _addr = int.parse(v, radix: 16);
                      }
                    })),
            ElevatedButton(
              child: const Text("-"),
              onPressed: () => _addr -= _addrIncSize,
            ),
            ElevatedButton(
              child: const Text("+"),
              onPressed: () => _addr += _addrIncSize,
            ),
          ]),
          ValueListenableBuilder<int>(
              valueListenable: addrNotifier,
              builder: (context, addr, child) =>
                  Text(_dump(debugger, addr), style: debugStyle)),
        ]),
      );
}
