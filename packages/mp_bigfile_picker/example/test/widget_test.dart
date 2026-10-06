import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mp_bigfile_picker_example/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows the pick button', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: ExamplePage()));
    expect(find.byIcon(Icons.folder_open), findsOneWidget);
  });
}
