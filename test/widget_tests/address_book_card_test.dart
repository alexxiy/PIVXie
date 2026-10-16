import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:paymint/models/isar/models/contact_entry.dart';
import 'package:paymint/models/isar/stack_theme.dart';
import 'package:paymint/pages/address_book_views/subviews/contact_popup.dart';
import 'package:paymint/providers/global/address_book_service_provider.dart';
import 'package:paymint/services/address_book_service.dart';
import 'package:paymint/themes/stack_colors.dart';
import 'package:paymint/utilities/util.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/widgets/address_book_card.dart';

import '../sample_data/theme_json.dart';
import 'address_book_card_test.mocks.dart';

class MockedFunctions extends Mock {
  void showDialog();
}

@GenerateMocks([AddressBookService])
void main() {
  testWidgets('test returns Contact Address Entry', (widgetTester) async {
    final service = MockAddressBookService();

    when(service.getContactById("default")).thenAnswer(
      (realInvocation) => ContactEntry(
        name: "John Doe",
        addresses: [
          ContactAddressEntry()
            ..coinName = Pivx(CryptoCurrencyNetwork.main).identifier
            ..address = "some bch address",
        ],
        isFavorite: true,
        customId: '',
      ),
    );

    await widgetTester.pumpWidget(
      ProviderScope(
        overrides: [addressBookServiceProvider.overrideWith((_) => service)],
        child: MaterialApp(
          theme: ThemeData(
            extensions: [
              StackColors.fromStackColorTheme(
                StackTheme.fromJson(json: lightThemeJsonMap),
              ),
            ],
          ),
          home: const AddressBookCard(contactId: "default"),
        ),
      ),
    );

    expect(find.text("John Doe"), findsOneWidget);
    expect(find.text("PIV"), findsOneWidget);
    expect(find.text(Pivx(CryptoCurrencyNetwork.main).ticker), findsOneWidget);

    if (Platform.isIOS || Platform.isAndroid) {
      await widgetTester.tap(find.byType(RawMaterialButton));
      expect(find.byType(ContactPopUp), findsOneWidget);
    } else if (Util.isDesktop) {
      expect(find.byType(RawMaterialButton), findsNothing);
    }
  });
}
