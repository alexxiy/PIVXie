import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/l10n/l10n.dart';
import 'package:paymint/utilities/format.dart';

void main() {
  testWidgets("Arabic dates use the digits 0-9", (tester) async {
    late String date, shortDate;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale("ar"),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => L10nRoot(child: child!),
        home: Builder(
          builder: (context) {
            date = Format.extractDateFrom(1641589563, localized: false);
            shortDate = Format.formatDate(DateTime(2025, 9, 10));
            return const SizedBox();
          },
        ),
      ),
    );

    expect(l10n.localeName, "ar");
    for (final text in [date, shortDate]) {
      expect(text, isNot(matches(RegExp("[٠-٩۰-۹]"))));
    }
    expect(date, contains("2022"));
    expect(date, contains("21:06"));
    expect(shortDate, contains("2025"));
  });
}
