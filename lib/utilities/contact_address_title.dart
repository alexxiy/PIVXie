import '../models/isar/models/contact_entry.dart';
import '../wallets/crypto_currency/coins/pivx.dart';

extension ContactAddressTitle on ContactAddressEntry {
  /// What the address is, worked out from the address itself. Contact
  /// addresses have no hand-typed label any more.
  String get kind {
    final c = coin;
    if (c is Pivx) {
      if (c.isShieldAddress(address)) return "Shielded";
      if (c.isExchangeAddress(address)) return "Exchange";
    }
    return "Transparent";
  }

  /// "Shielded (PIV)".
  String get title => "$kind (${coin.ticker})";
}
