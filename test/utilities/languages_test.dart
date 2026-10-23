import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/l10n/l10n.dart';
import 'package:paymint/utilities/enums/languages_enum.dart';

void main() {
  const ukrainianFirst = [Locale("fr", "FR"), Locale("uk", "UA"), Locale("ru")];
  const zhHantTW = Locale.fromSubtags(
    languageCode: "zh",
    scriptCode: "Hant",
    countryCode: "TW",
  );

  test("the language list has every translation and nothing else", () {
    expect(
      Language.values.map((e) => e.locale).toSet(),
      AppLocalizations.supportedLocales.toSet(),
    );
  });

  test("the system language is the first of the device's the app has", () {
    expect(Language.fromLocales(const [Locale("de", "AT")]), Language.german);
    expect(Language.fromLocales(ukrainianFirst), Language.ukrainian);
    expect(Language.fromLocales(const [zhHantTW]), Language.chinese);
  });

  test("a system language the app doesn't have falls back to English", () {
    expect(Language.fromLocales(const [Locale("fr", "FR")]), Language.english);
    expect(Language.fromLocales(const []), Language.english);
    // Also where Flutter's own matching is used.
    expect(AppLocalizations.supportedLocales.first, const Locale("en"));
  });

  test("stored codes", () {
    expect(Language.fromCode("ru"), Language.russian);
    // "" and the old "English (US)" mean the system language.
    expect(Language.fromCode(""), isNull);
    expect(Language.fromCode("English (US)"), isNull);
  });

  group("the app shows", () {
    Future<String> shown(WidgetTester tester, {Language? chosen}) async {
      late String title;
      await tester.pumpWidget(
        MaterialApp(
          locale: chosen?.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localeListResolutionCallback: Language.resolveLocale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) {
              title = AppLocalizations.of(context).languageTitle;
              return const SizedBox();
            },
          ),
        ),
      );
      return title;
    }

    void device(WidgetTester tester, List<Locale> locales) {
      tester.platformDispatcher.localesTestValue = locales;
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    }

    testWidgets("the system language", (tester) async {
      device(tester, ukrainianFirst);
      expect(await shown(tester), "Мова");
    });

    testWidgets("English for a language it doesn't have", (tester) async {
      device(tester, const [Locale("fr", "FR"), Locale("it", "IT")]);
      expect(await shown(tester), "Language");
    });

    testWidgets("the language chosen in settings", (tester) async {
      device(tester, ukrainianFirst);
      expect(await shown(tester, chosen: Language.japanese), "言語");
    });
  });
}
