import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:fnesemu_core/app_api.dart';
import 'pad_input.dart';

/// Floating action keys in the same staggered rows as a physical keyboard.
/// The buttons of a core are in the unified key order: the slots after the
/// directions are S Z X C / A D W / Q E / 1 2 3 4 / R, then the start slot
/// (Enter) and the select slot (Shift), shown to the left of Z when space allows.
class VirtualPadWidget extends StatelessWidget {
  final CoreController controller;
  final PadInput input;
  const VirtualPadWidget(
      {super.key, required this.controller, required this.input});
  static const keys = 'SZXC'
      'ADW'
      'QE'
      '1234'
      'R';
  static const keyWidth = 36.4;
  static const keyHeight = 57.2;
  static const gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final buttons = controller.buttons.skip(4).toList();
    final colors = Theme.of(context).colorScheme;
    Widget padKey(String caption, PadButton button) {
      return ListenableBuilder(
          listenable: input,
          builder: (_, __) => Tooltip(
                message: '$caption: ${button.name}',
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
                        key: ValueKey('action-key-$caption'),
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
                              child: Text(caption,
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

    Widget key(String letter) {
      final index = keys.indexOf(letter);
      if (index >= buttons.length || buttons[index] == PadButton.none) {
        return const SizedBox(width: keyWidth, height: keyHeight);
      }
      return padKey(letter, buttons[index]);
    }

    // The start and select slots, after the letter and digit slots.
    Widget systemKey(String caption, int index) {
      if (index >= buttons.length || buttons[index] == PadButton.none) {
        return const SizedBox.shrink();
      }
      return padKey(caption, buttons[index]);
    }

    final systemKeys = <Widget>[
      if (buttons.length > 15 && buttons[15] != PadButton.none)
        systemKey('Shift', 15),
      if (buttons.length > 14 && buttons[14] != PadButton.none)
        systemKey('Enter', 14),
    ];
    // Keep the Z row aligned with the staggered rows even when a core uses
    // a multi-letter action label that widens one of the upper rows.
    double rowWidth(String letters, int row) {
      var width = row * keyWidth / 2 + (letters.length - 1) * gap;
      for (final letter in letters.split('')) {
        final index = keys.indexOf(letter);
        final name = index < buttons.length ? buttons[index].name : '';
        if (name.length <= 1 ||
            (index < buttons.length && buttons[index] == PadButton.none)) {
          width += keyWidth;
        } else {
          final painter = TextPainter(
              text: TextSpan(
                  text: name,
                  style: DefaultTextStyle.of(context)
                      .style
                      .copyWith(fontSize: 15.6)),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context))
            ..layout();
          width += math.max(keyWidth, painter.width + 8);
          painter.dispose();
        }
      }
      return width;
    }

    final upperWidth = [
      rowWidth('1234', 0),
      rowWidth('QWER', 1),
      rowWidth('ASD', 2)
    ].reduce(math.max);
    final bottomInset = math.max(0.0, upperWidth - rowWidth('ZXC', 3));
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...[
                      '1234',
                      'QWER',
                      'ASD'
                    ].asMap().entries.map((row) => Padding(
                        padding: EdgeInsets.only(
                            left: row.key * keyWidth / 2,
                            top: row.key == 0 ? 0 : gap),
                        child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: gap,
                            children: row.value.split('').map(key).toList()))),
                  ])),
          Padding(
              padding: EdgeInsets.only(top: gap, right: bottomInset),
              child: Wrap(
                  textDirection: TextDirection.rtl,
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: gap,
                            children: 'ZXC'.split('').map(key).toList())),
                    if (systemKeys.isNotEmpty)
                      FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                              mainAxisSize: MainAxisSize.min,
                              spacing: gap,
                              children: systemKeys)),
                  ])),
        ]);
  }
}
