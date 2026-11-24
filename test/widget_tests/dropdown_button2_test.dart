import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// dropdown_button2 4.x is built on package:material_ui, whose Material and
/// localizations differ from those of package:flutter/material.dart this
/// app uses: there it fails with "No Material widget found". It stays on
/// 3.x until the app moves to material_ui.
void main() {
  testWidgets("DropdownButton2 works in the app's MaterialApp", (tester) async {
    int? picked;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: DropdownButton2<int>(
            valueListenable: ValueNotifier<int?>(1),
            items: const [
              DropdownItem(value: 1, child: Text("one")),
              DropdownItem(value: 2, child: Text("two")),
            ],
            onChanged: (v) => picked = v,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text("one"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("two").last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(picked, 2);
  });
}
