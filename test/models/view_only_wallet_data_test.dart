import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/keys/view_only_wallet_data.dart';

void main() {
  // Stored in secure storage and in Stack backups by type index.
  test("view only types keep their stored indices", () {
    expect(ViewOnlyWalletType.xPub.index, 2);
    expect(ViewOnlyWalletType.saplingViewingKey.index, 4);
  });

  test("a shield viewing key round-trips through JSON", () {
    const key = "pxviews1qexamplekey";
    final data = SaplingViewingKeyViewOnlyWalletData(
      walletId: "w",
      viewingKey: key,
    );
    final read = ViewOnlyWalletData.fromJsonEncodedString(
      data.toJsonEncodedString(),
      walletId: "w",
    );
    expect(read, isA<SaplingViewingKeyViewOnlyWalletData>());
    expect((read as SaplingViewingKeyViewOnlyWalletData).viewingKey, key);
    expect(read.type, ViewOnlyWalletType.saplingViewingKey);
  });

  test("an xpub still round-trips through JSON", () {
    final data = ExtendedKeysViewOnlyWalletData(
      walletId: "w",
      xPubs: [XPub(path: "m/44'/119'/0'", encoded: "xpub6example")],
    );
    final read = ViewOnlyWalletData.fromJsonEncodedString(
      data.toJsonEncodedString(),
      walletId: "w",
    );
    expect(read, isA<ExtendedKeysViewOnlyWalletData>());
    expect(
      (read as ExtendedKeysViewOnlyWalletData).xPubs.single.encoded,
      "xpub6example",
    );
  });
}
