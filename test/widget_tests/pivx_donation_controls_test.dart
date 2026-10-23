import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/stack_theme.dart';
import 'package:paymint/pages/pivx_donation/pivx_donation_controls.dart';
import 'package:paymint/pages/pivx_donation/pivx_donation_stage.dart';
import 'package:paymint/themes/stack_colors.dart';

import '../sample_data/theme_json.dart';

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData(
    extensions: [
      StackColors.fromStackColorTheme(
        StackTheme.fromJson(json: lightThemeJsonMap),
      ),
    ],
  ),
  home: Scaffold(
    body: Center(child: SizedBox(width: 350, child: child)),
  ),
);

void main() {
  group("tier slider", () {
    const labels = [r"$1", r"$5", r"$10", r"$20", r"$50", r"$100", "Custom"];

    Future<List<int>> pump(WidgetTester tester) async {
      final changes = <int>[];
      var index = 1;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => PivxDonationTierSlider(
              labels: labels,
              index: index,
              onChanged: (i) => setState(() {
                changes.add(i);
                index = i;
              }),
              palette: PivxDonationPalette.shielded,
              semanticLabel: "Donation size",
            ),
          ),
        ),
      );
      return changes;
    }

    testWidgets("a tap picks the stop under it", (tester) async {
      final changes = await pump(tester);
      await tester.tap(find.text(r"$20"));
      await tester.pumpAndSettle();
      expect(changes, [3]);

      // The stop that's already on does nothing.
      await tester.tap(find.text(r"$20"));
      await tester.pumpAndSettle();
      expect(changes, [3]);
    });

    testWidgets("a drag goes stop by stop", (tester) async {
      final changes = await pump(tester);
      final from = tester.getCenter(find.text(r"$5"));
      final to = tester.getCenter(find.text(r"$100"));
      await tester.timedDragFrom(
        from,
        to - from,
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(changes, [2, 3, 4, 5]);
    });
  });

  group("slide to confirm", () {
    Future<List<int>> pump(WidgetTester tester, {bool enabled = true}) async {
      final calls = <int>[];
      await tester.pumpWidget(
        _app(
          PivxSlideToConfirm(
            label: "Slide to brew",
            palette: PivxDonationPalette.transparent,
            enabled: enabled,
            onConfirmed: () async => calls.add(1),
          ),
        ),
      );
      return calls;
    }

    Future<void> slide(WidgetTester tester, double fraction) async {
      final knob = find.byIcon(Icons.keyboard_double_arrow_right_rounded);
      // The knob travels the width less itself and its margins.
      await tester.drag(knob, Offset((350 - 56) * fraction, 0));
      await tester.pumpAndSettle();
    }

    testWidgets("all the way confirms, once", (tester) async {
      final calls = await pump(tester);
      await slide(tester, 1);
      expect(calls, [1]);
    });

    testWidgets("half way springs back", (tester) async {
      final calls = await pump(tester);
      await slide(tester, 0.5);
      expect(calls, isEmpty);
      // Back at the start: another full slide still works.
      await slide(tester, 1);
      expect(calls, [1]);
    });

    testWidgets("disabled does nothing", (tester) async {
      final calls = await pump(tester, enabled: false);
      await slide(tester, 1);
      expect(calls, isEmpty);
    });
  });
}
