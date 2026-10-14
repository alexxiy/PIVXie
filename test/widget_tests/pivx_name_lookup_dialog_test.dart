import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/models/contact_entry.dart';
import 'package:paymint/models/isar/stack_theme.dart';
import 'package:paymint/pages/send_view/sub_widgets/pivx_name_lookup.dart';
import 'package:paymint/services/pivx_name/pivx_name_resolver.dart';
import 'package:paymint/themes/stack_colors.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

import '../sample_data/theme_json.dart';

const _address =
    "ps19wd4eft4mw2mlwad6tjrny5hlvtdxymatu2e3dge7jr6scqask0llvdsa3xhx06499vmzymatxr";

/// Answers lookups from a script.
class _FakeResolver extends PivxNameResolver {
  _FakeResolver(this.answers)
    : super(
        PivxNameService(
          indexer: Uri.parse("https://indexer.test"),
          anchor: "0x0",
          rpcs: [Uri.parse("https://a.test"), Uri.parse("https://b.test")],
          epochs: const {1},
        ),
      );

  final List<FutureOr<PivxNameLookup> Function()> answers;
  var lookups = 0;
  var caughtUpAnswer = false;

  @override
  Future<PivxNameLookup> lookup(String name) async => answers[lookups++]();

  @override
  Future<bool> caughtUp() async => caughtUpAnswer;
}

void main() {
  final pivx = Pivx(CryptoCurrencyNetwork.main);

  /// Opens the lookup from a button and records what it returned.
  Future<List<PivxNameVerified?>> open(
    WidgetTester tester,
    PivxNameResolver resolver, {
    List<ContactEntry> contacts = const [],
  }) async {
    final results = <PivxNameVerified?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: [
            StackColors.fromStackColorTheme(
              StackTheme.fromJson(json: lightThemeJsonMap),
            ),
          ],
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
              await lookUpPivxNameForSend(
                context: context,
                coin: pivx,
                name: "alexxiy.pivx",
                contacts: contacts,
                resolver: resolver,
              ),
            ),
            child: const Text("go"),
          ),
        ),
      ),
    );
    await tester.tap(find.text("go"));
    await tester.pump();
    return results;
  }

  testWidgets("returns the verified address and nothing else", (t) async {
    final resolver = _FakeResolver([
      () => const PivxNameVerified("alexxiy.pivx", _address),
    ]);
    final results = await open(t, resolver);
    await t.pumpAndSettle();
    expect(results.single?.address, _address);
  });

  testWidgets("cancel drops a lookup still running", (t) async {
    final pending = Completer<PivxNameLookup>();
    final results = await open(t, _FakeResolver([() => pending.future]));
    expect(find.text("Checking alexxiy.pivx"), findsOneWidget);
    await t.tap(find.text("Cancel"));
    await t.pumpAndSettle();
    expect(results, [null]);
    // The answer arriving afterwards changes nothing.
    pending.complete(const PivxNameVerified("alexxiy.pivx", _address));
    await t.pumpAndSettle();
    expect(results, [null]);
    expect(find.text("go"), findsOneWidget);
  });

  testWidgets("waits while the server is behind, then continues", (t) async {
    final resolver = _FakeResolver([
      () => const PivxNameIndexerBehind("alexxiy.pivx", nameMissing: false),
      () => const PivxNameVerified("alexxiy.pivx", _address),
    ]);
    final results = await open(t, resolver);
    await t.pump();
    expect(find.text("Waiting for PIVX.name"), findsOneWidget);
    // Nothing to send while waiting: only Cancel.
    expect(find.text("Try again"), findsNothing);

    await t.pump(const Duration(seconds: 16));
    expect(resolver.lookups, 1, reason: "not caught up yet: no lookup");
    expect(results, isEmpty);

    resolver.caughtUpAnswer = true;
    await t.pump(const Duration(seconds: 15));
    await t.pumpAndSettle();
    expect(resolver.lookups, 2);
    expect(results.single?.address, _address);
  });

  testWidgets("a refused registry state offers no way on", (t) async {
    final resolver = _FakeResolver([
      () => throw const PivxNameException(
        PivxNameError.unanchoredRoot,
        "never published",
      ),
    ]);
    final results = await open(t, resolver);
    await t.pumpAndSettle();
    expect(find.text("Can't send to alexxiy.pivx"), findsOneWidget);
    expect(find.text("Try again"), findsNothing);
    await t.tap(find.text("Close"));
    await t.pumpAndSettle();
    expect(results, [null]);
  });

  testWidgets("a server out of reach can be tried again", (t) async {
    final resolver = _FakeResolver([
      () => throw const PivxNameException(
        PivxNameError.indexerUnreachable,
        "Couldn't reach the PIVX.name server.",
      ),
      () => const PivxNameVerified("alexxiy.pivx", _address),
    ]);
    final results = await open(t, resolver);
    await t.pumpAndSettle();
    await t.tap(find.text("Try again"));
    await t.pumpAndSettle();
    expect(results.single?.address, _address);
  });

  testWidgets("a name that is also a contact is not looked up", (t) async {
    final resolver = _FakeResolver([]);
    final contact = ContactEntry(
      name: "Alexxiy.pivx ",
      addresses: [],
      isFavorite: false,
      customId: "1",
    );
    final results = await open(t, resolver, contacts: [contact]);
    await t.pumpAndSettle();
    expect(find.text("alexxiy.pivx is also a contact"), findsOneWidget);
    await t.tap(find.text("Ok"));
    await t.pumpAndSettle();
    expect(results, [null]);
    expect(resolver.lookups, 0);
  });
}
