import '../../../models/keys/view_only_wallet_data.dart';
import '../../crypto_currency/interfaces/view_only_option_currency_interface.dart';
import '../wallet.dart';

mixin ViewOnlyOptionInterface<T extends ViewOnlyOptionCurrencyInterface>
    on Wallet<T> {
  ViewOnlyWalletType get viewOnlyType => info.viewOnlyWalletType!;

  bool get isViewOnly => info.isViewOnly;

  Future<void> recoverViewOnly();

  Future<ViewOnlyWalletData> getViewOnlyWalletData() async {
    if (!isViewOnly) {
      throw Exception("This is not a view only wallet");
    }

    final encoded = await secureStorageInterface.read(
      key: Wallet.getViewOnlyWalletDataSecStoreKey(walletId: walletId),
    );

    return ViewOnlyWalletData.fromJsonEncodedString(
      encoded!,
      walletId: walletId,
    );
  }
}

/// What menus and titles call the wallet's secret: a view-only wallet has
/// keys, every other one a seed.
String walletSecretTitle(Wallet wallet) =>
    wallet is ViewOnlyOptionInterface && wallet.isViewOnly
    ? "Wallet keys"
    : "Wallet seed";
