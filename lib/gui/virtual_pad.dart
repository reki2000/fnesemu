import 'package:flutter/material.dart';

import 'package:fnesemu_core/core/core_api.dart';
import 'pad_input.dart';

/// Floating action keys in the same staggered rows as a physical keyboard.
class VirtualPadWidget extends StatelessWidget {
  final CoreController controller;
  final PadInput input;
  const VirtualPadWidget(
      {super.key, required this.controller, required this.input});
  static const keys = 'ASZXCQWERD';
  static const keyWidth = 36.4;
  static const keyHeight = 57.2;
  static const gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final buttons = controller.buttons.skip(4).toList();
    final colors = Theme.of(context).colorScheme;
    Widget key(String letter) {
      final index = keys.indexOf(letter);
      if (index >= buttons.length || buttons[index] == PadButton.none) {
        return const SizedBox(width: keyWidth, height: keyHeight);
      }
      final button = buttons[index];
      return ListenableBuilder(
          listenable: input,
          builder: (_, __) => Tooltip(
                message: '$letter: ${button.name}',
                child: Material(
                  color: input.pressed.contains(button)
                      ? colors.primary
                      : colors.surfaceContainerHigh.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(6),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) =>
                        input.setSource((button, event.pointer), {button}),
                    onPointerUp: (event) =>
                        input.setSource((button, event.pointer), {}),
                    onPointerCancel: (event) =>
                        input.setSource((button, event.pointer), {}),
                    child: Container(
                        key: ValueKey('action-key-$letter'),
                        constraints: const BoxConstraints(minWidth: keyWidth),
                        width: button.name.length == 1 ? keyWidth : null,
                        height: keyHeight,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Stack(alignment: Alignment.center, children: [
                          Text(button.name,
                              style: TextStyle(
                                  fontSize: 15.6,
                                  color: input.pressed.contains(button)
                                      ? colors.onPrimary
                                      : colors.onSurface)),
                          Positioned(
                              top: 2,
                              left: 0,
                              child: Text(letter,
                                  style: TextStyle(
                                      fontSize: 11.7,
                                      color: input.pressed.contains(button)
                                          ? colors.onPrimary
                                          : colors.onSurfaceVariant))),
                        ])),
                  ),
                ),
              ));
    }

    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: ['QWER', 'ASD', 'ZXC']
            .asMap()
            .entries
            .map((row) => Padding(
                  padding: EdgeInsets.only(
                      left: row.key * keyWidth / 2,
                      top: row.key == 0 ? 0 : gap),
                  child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: gap,
                      children: row.value.split('').map(key).toList()),
                ))
            .toList());
  }
}
