import 'package:flutter/material.dart';

import 'package:fnesemu_core/app_api.dart';
import '../../styles.dart';
import 'hex_pager.dart';

// get 40 lines of disassemble string

class DebugDisasm extends StatefulWidget {
  final Debugger debugger;
  final int cpuNo;

  final int backwardLines;
  final int forwardLines;
  final double width;
  final int addrBits;

  const DebugDisasm(
      {super.key,
      required this.debugger,
      required this.cpuNo,
      this.addrBits = 16,
      this.backwardLines = 5,
      this.forwardLines = 40,
      this.width = 320});

  int get addrMask => (1 << addrBits) - 1;

  @override
  State<DebugDisasm> createState() => _DebugDisasmState();
}

class _DebugDisasmState extends State<DebugDisasm> {
  late final ValueNotifier<int> addrNotifier;
  final margin10 = const EdgeInsets.all(2.0);
  late final FocusNode node;

  Debugger get debugger => widget.debugger;
  int get cpuNo => widget.cpuNo;

  @override
  void initState() {
    super.initState();
    addrNotifier = ValueNotifier<int>(debugger.disasmAddress(cpuNo));
    node = FocusNode();
  }

  @override
  void dispose() {
    addrNotifier.dispose();
    node.dispose();
    super.dispose();
  }

  List<(int, String)> _asm(int addr, int lines) {
    final result = List<(int, String)>.empty(growable: true);

    for (int i = 0; i < lines; i++) {
      final (asm, inc) = debugger.disasm(cpuNo, addr);
      result.add((addr, asm));
      addr += inc;
    }

    return result;
  }

  // To show backward lines correctly, we need to start from earlier address and succeeding to the current address
  List<(int, String)> _backward(int addr, int lines) {
    final result = List.filled(lines, (0, ""), growable: true);

    var current = addr - lines * 6;
    while (current < addr) {
      final (asm, inc) = debugger.disasm(cpuNo, current);
      result.add((current, asm));
      current += inc;
    }

    return result.sublist(result.length - lines);
  }

  @override
  Widget build(BuildContext context) {
    node.requestFocus();
    return Container(
        width: widget.width,
        margin: margin10,
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Focus(
              focusNode: node,
              child: ValueListenableBuilder<int>(
                  valueListenable: addrNotifier,
                  builder: (_, addr, __) => Column(
                          mainAxisAlignment: MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            HexAddressPager(
                                address: addr,
                                bits: widget.addrBits,
                                fieldWidth: 60,
                                spacing: 3,
                                leadingSteps: const [
                                  ('--', -0x400),
                                  ('-', -0x20)
                                ],
                                trailingSteps: const [
                                  ('+', 0x20),
                                  ('++', 0x400)
                                ],
                                onAddress: (value) =>
                                    addrNotifier.value = value),
                            SelectableText(
                              [
                                ..._backward(addr, widget.backwardLines),
                                ..._asm(addr, widget.forwardLines)
                              ]
                                  .map((s) => (s.$1 == addr ? "*" : " ") + s.$2)
                                  .join("\n"),
                              style: debugStyle,
                              showCursor: true,
                            ),
                          ])),
            )));
  }
}
