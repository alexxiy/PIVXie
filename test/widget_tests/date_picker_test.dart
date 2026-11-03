import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/stack_theme.dart';
import 'package:paymint/themes/stack_colors.dart';
import 'package:paymint/widgets/date_picker/date_picker.dart';

import '../sample_data/theme_json.dart';

Future<void> _openPicker(
  WidgetTester tester, {
  required Size screen,
  List<DateTime?> value = const [],
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final theme = StackTheme.fromJson(json: lightThemeJsonMap);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: [StackColors.fromStackColorTheme(theme)]),
      home: Builder(
        builder: (context) => Material(
          child: TextButton(
            onPressed: () => showSWDatePicker(context, value: value),
            child: const Text("Open"),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text("Open"));
  await tester.pumpAndSettle();
}

void main() {
  // calendar_date_picker2 4.x failed here with "No Material widget found"
  // (a gray box in release builds), see pubspec.template.yaml.
  testWidgets("Date picker dialog opens on a phone", (tester) async {
    await _openPicker(tester, screen: const Size(412, 915));

    expect(tester.takeException(), isNull);
    expect(find.text("Cancel"), findsOneWidget);
    expect(find.text("Ok"), findsOneWidget);
  });

  testWidgets("Long month names fit the header on a narrow phone", (
    tester,
  ) async {
    await _openPicker(
      tester,
      screen: const Size(360, 800),
      value: [DateTime(2025, 9, 10)],
    );

    expect(tester.takeException(), isNull);
    expect(find.text("Sep"), findsOneWidget);
    expect(find.text("2025"), findsOneWidget);
  });
}
