import '../l10n/l10n.dart';
import '../models/isar/models/contact_entry.dart';
import '../wallets/crypto_currency/coins/pivx.dart';

extension ContactAddressTitle on ContactAddressEntry {
  /// What the address is, worked out from the address itself. Contact
  /// addresses have no hand-typed label any more.
  String get kind {
    final c = coin;
    if (c is Pivx) {
      if (c.isShieldAddress(address)) return l10n.addressKindShielded;
      if (c.isExchangeAddress(address)) return l10n.addressKindExchange;
    }
    return l10n.addressKindTransparent;
  }

  /// "Shielded (PIV)".
  String get title => "$kind (${coin.ticker})";
}
