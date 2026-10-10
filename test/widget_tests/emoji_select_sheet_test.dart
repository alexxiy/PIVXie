import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/stack_theme.dart';
import 'package:paymint/themes/stack_colors.dart';
import 'package:paymint/widgets/emoji_select_sheet.dart';

import '../sample_data/theme_json.dart';

void main() {
  testWidgets("Widget displays correctly", (tester) async {
    const emojiSelectSheet = EmojiSelectSheet();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: [
            StackColors.fromStackColorTheme(
              StackTheme.fromJson(json: lightThemeJsonMap),
            ),
          ],
        ),
        home: const Material(child: emojiSelectSheet),
      ),
    );

    expect(find.byWidget(emojiSelectSheet), findsOneWidget);
    expect(find.text("Select emoji"), findsOneWidget);
  });
}
