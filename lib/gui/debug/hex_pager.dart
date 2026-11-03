import 'package:flutter/material.dart';

import '../../styles.dart';

/// The number of hexadecimal digits needed to show an address of [bits].
int hexAddressDigits(int bits) => (bits + 3) ~/ 4;

/// Formats [value] as a zero padded hexadecimal address of [bits].
String formatHexAddress(int value, int bits) =>
    value.toRadixString(16).padLeft(hexAddressDigits(bits), '0');

/// Parses [text] as a hexadecimal address of [bits], returning null when the text is not exactly one full address or is not valid hexadecimal, so invalid input never throws.
int? parseHexAddress(String text, int bits) {
  if (text.length != hexAddressDigits(bits)) {
    return null;
  }
  return int.tryParse(text, radix: 16);
}

/// A hexadecimal address field with step buttons on either side of it, shared by the debugger panes that page through addresses.
/// The step buttons are given as (label, offset) pairs, and every address reported through [onAddress] is masked to [bits].
class HexAddressPager extends StatefulWidget {
  final int address;
  final int bits;
  final double fieldWidth;
  final List<(String, int)> leadingSteps;
  final List<(String, int)> trailingSteps;
  final ValueChanged<int> onAddress;
  final bool elevated;
  final double spacing;

  const HexAddressPager(
      {super.key,
      required this.address,
      required this.bits,
      required this.onAddress,
      this.fieldWidth = 80,
      this.leadingSteps = const [],
      this.trailingSteps = const [],
      this.elevated = false,
      this.spacing = 0});

  int get mask => (1 << bits) - 1;

  @override
  State<HexAddressPager> createState() => _HexAddressPagerState();
}

class _HexAddressPagerState extends State<HexAddressPager> {
  late final TextEditingController _input;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(
        text: formatHexAddress(widget.address & widget.mask, widget.bits));
  }

  @override
  void didUpdateWidget(HexAddressPager old) {
    super.didUpdateWidget(old);
    if (widget.address != old.address) {
      final text =
          formatHexAddress(widget.address & widget.mask, widget.bits);
      if (_input.text != text) {
        _input.text = text;
      }
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _go(int offset) {
    final value = (widget.address + offset) & widget.mask;
    _input.text = formatHexAddress(value, widget.bits);
    widget.onAddress(value);
  }

  void _entered(String text) {
    final value = parseHexAddress(text, widget.bits);
    if (value != null) {
      widget.onAddress(value & widget.mask);
    }
  }

  Widget _step((String, int) step) => widget.elevated
      ? ElevatedButton(
          onPressed: () => _go(step.$2), child: Text(step.$1))
      : TextButton(onPressed: () => _go(step.$2), child: Text(step.$1));

  @override
  Widget build(BuildContext context) => Row(spacing: widget.spacing, children: [
        for (final step in widget.leadingSteps) _step(step),
        SizedBox(
            width: widget.fieldWidth,
            child: TextField(
                controller: _input,
                decoration: denseTextDecoration,
                onChanged: _entered)),
        for (final step in widget.trailingSteps) _step(step),
      ]);
}
