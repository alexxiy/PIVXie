import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:paymint/models/isar/stack_theme.dart';
import 'package:paymint/models/notification_model.dart';
import 'package:paymint/notifications/notification_card.dart';
import 'package:paymint/themes/coin_icon_provider.dart';
import 'package:paymint/themes/stack_colors.dart';
import 'package:paymint/themes/theme_service.dart';
import 'package:paymint/utilities/assets.dart';

import '../sample_data/theme_json.dart';
import 'notification_card_test.mocks.dart';

@GenerateMocks([ThemeService])
void main() {
  testWidgets("test notification card", (widgetTester) async {
    final key = UniqueKey();
    final mockThemeService = MockThemeService();
    final theme = StackTheme.fromJson(json: lightThemeJsonMap);

    when(mockThemeService.getTheme(themeId: "light")).thenAnswer((_) => theme);

    final notificationCard = NotificationCard(
      key: key,
      notification: NotificationModel(
        id: 1,
        title: "notification title",
        description: "notification description",
        iconAssetName: Assets.svg.plus,
        date: DateTime.parse("1662544771"),
        walletId: "wallet id",
        read: true,
        shouldWatchForUpdates: true,
        coinName: "Bitcoin",
      ),
    );

    await widgetTester.pumpWidget(
      ProviderScope(
        overrides: [
          pThemeService.overrideWith((_) => mockThemeService),
          coinIconProvider.overrideWith(
            (_, _) =>
                "${Directory.current.path}/test/sample_data/light/assets/dummy.svg",
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: [StackColors.fromStackColorTheme(theme)],
          ),
          home: Material(child: notificationCard),
        ),
      ),
    );

    expect(find.byWidget(notificationCard), findsOneWidget);
    expect(find.text("notification title"), findsOneWidget);
    expect(find.text("notification description"), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
  });
}
