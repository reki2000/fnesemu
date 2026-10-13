import 'package:flutter/material.dart';
import 'package:fnesemu_core/app_api.dart';

import '../../styles.dart';

const _bytesPerLine = 16; //22; // 22 for exodus view

String _dump(
    Debugger debugger, int cpuNo, int start, int bits, int mask, int rowCount) {
  final lines = <String>[];

  for (int row = 0; row < rowCount; row++) {
    final base = start + row * _bytesPerLine;
    final bytes = List.generate(_bytesPerLine,
        (i) => debugger.read((base + i) & mask, cpuNo: cpuNo).x2);
    final address =
        (base & mask).toRadixString(16).padLeft((bits + 3) ~/ 4, '0');
    lines.add("$address: ${bytes.join(" ")}");
  }

  return lines.join("\n");
}

class MemPane extends StatefulWidget {
  final Debugger debugger;
  final int cpuNo;
  final int visibleLines;
  const MemPane(
      {super.key,
      required this.debugger,
      required this.cpuNo,
      required this.visibleLines});
  @override
  State<MemPane> createState() => _MemPaneState();
}

class _MemPaneState extends State<MemPane> {
  final _scroll = ScrollController();
  late final _address = ValueNotifier<int>(widget.debugger.state.memAddress);
  late final _input = TextEditingController(text: _format(_address.value));
  Debugger get debugger => widget.debugger;
  int get _bits => debugger.cpuInfo(widget.cpuNo).pcBitWidth;
  int get _mask => (1 << _bits) - 1;
  int get _digits => (_bits + 3) ~/ 4;
  int get _pageSize => widget.visibleLines * _bytesPerLine;
  String _format(int value) =>
      (value & _mask).toRadixString(16).padLeft(_digits, '0');

  void _setAddress(int value) {
    final address = value & _mask;
    debugger.setMemoryAddress(address);
    _address.value = address;
    _input.text = _format(address);
  }

  @override
  void didUpdateWidget(MemPane old) {
    super.didUpdateWidget(old);
    final address = debugger.state.memAddress & _mask;
    if (address != _address.value) {
      _address.value = address;
      _input.text = _format(address);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _address.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
      alignment: Alignment.topLeft,
      margin: const EdgeInsets.all(2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(
              width: 80,
              child: TextField(
                  controller: _input,
                  onChanged: (text) {
                    final address = int.tryParse(text, radix: 16);
                    if (text.length == _digits && address != null) {
                      _setAddress(address);
                    }
                  })),
          ElevatedButton(
              onPressed: () => _setAddress(_address.value - _pageSize),
              child: const Text('-')),
          ElevatedButton(
              onPressed: () => _setAddress(_address.value + _pageSize),
              child: const Text('+')),
        ]),
        ValueListenableBuilder<int>(
            valueListenable: _address,
            builder: (context, address, _) => Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                interactive: true,
                child: SingleChildScrollView(
                  key: const ValueKey('memory-dump-scroll'),
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SelectableText(
                          _dump(debugger, widget.cpuNo, address, _bits, _mask,
                              widget.visibleLines),
                          style: debugStyle,
                          showCursor: true)),
                ))),
      ]));
}
