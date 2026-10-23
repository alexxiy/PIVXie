import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/stack_theme.dart';
import 'package:paymint/themes/stack_colors.dart';
import 'package:paymint/widgets/date_picker/date_picker.dart';

import '../sample_data/theme_json.dart';

void main() {
  // calendar_date_picker2 4.x failed here with "No Material widget found"
  // (a gray box in release builds), see pubspec.template.yaml.
  testWidgets("Date picker dialog opens on a phone", (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = StackTheme.fromJson(json: lightThemeJsonMap);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: [StackColors.fromStackColorTheme(theme)],
        ),
        home: Builder(
          builder: (context) => Material(
            child: TextButton(
              onPressed: () => showSWDatePicker(context),
              child: const Text("Open"),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text("Open"));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text("Cancel"), findsOneWidget);
    expect(find.text("Ok"), findsOneWidget);
  });
}
