// Flutter imports:
import 'package:flutter/material.dart';

import '../../core/debugger.dart';
// Project imports:
import '../../styles.dart';
import '../../util/util.dart';

// get 40 lines of disassemble string

class DebugDisasm extends StatelessWidget {
  final Debugger debugger;
  final int cpuNo;

  final int backwardLines;
  final int forwardLines;
  final double width;
  final int addrBits;
  final int addrMask;

  final addrNotifier = ValueNotifier<int>(0);

  DebugDisasm(
      {super.key,
      required this.debugger,
      required this.cpuNo,
      this.addrBits = 16,
      this.backwardLines = 5,
      this.forwardLines = 40,
      this.width = 320})
      : addrMask = 1 << addrBits - 1 {
    addrNotifier.value = debugger.opt.disasmAddress[cpuNo];
  }

  final margin10 = const EdgeInsets.all(10.0);
  final node = FocusNode();

  List<Pair<int, String>> _asm(int addr, int lines) {
    final result = List<Pair<int, String>>.empty(growable: true);

    for (int i = 0; i < lines; i++) {
      final asm = debugger.disasm(cpuNo, addr);
      result.add(Pair(addr, asm.i0));
      addr += asm.i1;
    }

    return result;
  }

  // To show backward lines correctly, we need to start from earlier address and succesding to the current address
  List<Pair<int, String>> _backward(int addr, int lines) {
    final result = List.filled(lines, const Pair(0, ""), growable: true);

    var current = addr - lines * 6;
    while (current < addr) {
      final asm = debugger.disasm(cpuNo, current);
      result.add(Pair(current, asm.i0));
      current += asm.i1;
    }

    return result.sublist(result.length - lines);
  }

  _button(String text, void Function() func) =>
      TextButton(onPressed: func, style: textButtonMinimum, child: Text(text));

  _addrInc(int offset) {
    addrNotifier.value = (addrNotifier.value + offset) & addrMask;
  }

  @override
  Widget build(BuildContext context) {
    node.requestFocus;
    return Container(
        width: width,
        margin: margin10,
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Focus(
              focusNode: node,
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      _button("--", () => _addrInc(-0x400)),
                      _button("-", () => _addrInc(-0x20)),
                      SizedBox(
                          width: 60,
                          child: TextField(
                              decoration: denseTextDecoration,
                              onChanged: (v) {
                                if (v.length == addrBits >> 2) {
                                  addrNotifier.value = int.parse(v, radix: 16);
                                }
                              })),
                      _button("+", () => _addrInc(0x20)),
                      _button("++", () => _addrInc(0x400)),
                    ]),
                    ValueListenableBuilder<int>(
                        valueListenable: addrNotifier,
                        builder: (_, addr, __) => SelectableText(
                              [
                                ..._backward(addr, backwardLines),
                                ..._asm(addr, forwardLines)
                              ]
                                  .map((s) => (s.i0 == addr ? "*" : " ") + s.i1)
                                  .join("\n"),
                              style: debugStyle,
                              showCursor: true,
                            )),
                  ]),
            )));
  }
}
