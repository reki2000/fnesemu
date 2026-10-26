import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/analog_stick.dart';
import 'package:fnesemu/gui/core_view.dart';
import 'package:fnesemu/gui/direction_pad.dart';
import 'package:fnesemu/gui/pad_input.dart';
import 'package:fnesemu/gui/ticker_image.dart';
import 'package:fnesemu/gui/virtual_pad.dart';
import 'package:fnesemu_core/app_api.dart';

class _AnalogController extends CoreController {
  _AnalogController() : super((_) {}, (_) {}, (_) {}, Sram());
  @override
  List<PadAxis> get axes =>
      const [PadAxis.leftX, PadAxis.leftY, PadAxis.rightX, PadAxis.rightY];
}

void main() {
  test('the stick is 0.8 times the direction pad', () {
    expect(AnalogStick.diameter, DirectionPad.diameter * 0.8);
  });

  test('the dead zone reads 0 and the edge reads 1.0', () {
    const r = AnalogStick.radius;
    expect(AnalogStick.valueOf(Offset.zero), (0.0, 0.0));
    expect(AnalogStick.valueOf(const Offset(r * 0.3, 0)), (0.0, 0.0));
    expect(AnalogStick.valueOf(const Offset(r, 0)), (1.0, 0.0));
    expect(AnalogStick.valueOf(const Offset(0, -r)), (0.0, -1.0));
    final (x, _) = AnalogStick.valueOf(const Offset(r * 0.65, 0));
    expect(x, moreOrLessEquals(0.5));
  });

  test('a diagonal keeps its length within 1.0', () {
    final (x, y) = AnalogStick.valueOf(const Offset(100, 100));
    expect(x * x + y * y, moreOrLessEquals(1.0));
    expect(x, moreOrLessEquals(y));
  });

  test('a touch outside the circle is clamped to the edge', () {
    final offset = AnalogStick.clamped(const Offset(500, 64));
    expect(offset.distance, moreOrLessEquals(AnalogStick.radius));
  });

  test('sources of an axis combine by the largest magnitude', () {
    final input = PadInput();
    addTearDown(input.dispose);
    input.setAxisSource('a', {PadAxis.leftX: 0.4});
    input.setAxisSource('b', {PadAxis.leftX: -0.9});
    expect(input.axis(0, PadAxis.leftX), -0.9);
    expect(input.axis(1, PadAxis.leftX), 0);
    input.setAxisSource('b', {});
    expect(input.axis(0, PadAxis.leftX), 0.4);
    input.clear();
    expect(input.axis(0, PadAxis.leftX), 0);
    input.enabled = false;
    input.setAxisSource('a', {PadAxis.leftX: 1});
    expect(input.axes, isEmpty);
  });

  testWidgets('dragging moves the axes and shows the touched dot',
      (tester) async {
    final input = PadInput();
    addTearDown(input.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: AnalogStick(
                    input: input,
                    axisX: PadAxis.leftX,
                    axisY: PadAxis.leftY)))));
    final origin = tester.getTopLeft(find.byType(AnalogStick));
    const center = Offset(AnalogStick.diameter / 2, AnalogStick.diameter / 2);
    AnalogStickPainter painter() => tester
        .widget<CustomPaint>(find.descendant(
            of: find.byType(AnalogStick), matching: find.byType(CustomPaint)))
        .painter! as AnalogStickPainter;

    final gesture = await tester.startGesture(origin + center);
    await tester.pump();
    expect(input.axis(0, PadAxis.leftX), 0);
    expect(painter().dot, Offset.zero);

    await gesture.moveTo(origin + center + const Offset(AnalogStick.radius, 0));
    await tester.pump();
    expect(input.axis(0, PadAxis.leftX), moreOrLessEquals(1.0));
    expect(input.axis(0, PadAxis.leftY), moreOrLessEquals(0.0));
    expect(painter().dot!.dx, moreOrLessEquals(AnalogStick.radius));

    // dragging far outside keeps the dot on the edge
    await gesture.moveTo(origin + center + const Offset(0, 300));
    await tester.pump();
    expect(input.axis(0, PadAxis.leftY), moreOrLessEquals(1.0));
    expect(painter().dot!.distance, moreOrLessEquals(AnalogStick.radius));

    await gesture.up();
    await tester.pump();
    expect(input.axes, isEmpty);
    expect(painter().dot, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the sticks are shown above the pads when the core has axes',
      (tester) async {
    final controller = _AnalogController();
    final container = ImageContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CoreView(
                controller: controller,
                container: container,
                portrait: false))));
    final left = tester.getRect(find.byKey(const ValueKey('left-stick')));
    final right = tester.getRect(find.byKey(const ValueKey('right-stick')));
    final direction = tester.getRect(find.byType(DirectionPad));
    final actions = tester.getRect(find.byType(VirtualPadWidget));
    expect(left.size, const Size(AnalogStick.diameter, AnalogStick.diameter));
    expect(left.bottom, lessThan(direction.top));
    expect(left.center.dx, direction.center.dx);
    expect(right.bottom, lessThan(actions.top));
    expect(right.right, actions.right);

    // the core reads what the stick sets
    final gesture = await tester
        .startGesture(left.center + const Offset(AnalogStick.radius, 0));
    await tester.pump();
    expect(controller.input.axis(0, PadAxis.leftX), moreOrLessEquals(1.0));
    await gesture.up();
    expect(controller.input.axis(0, PadAxis.leftX), 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no stick is shown for a core without axes', (tester) async {
    final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
    final container = ImageContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CoreView(controller: controller, container: container))));
    expect(find.byType(AnalogStick), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
