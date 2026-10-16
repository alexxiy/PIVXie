import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;

import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/enums/derive_path_type_enum.dart';
import '../interfaces/view_only_option_currency_interface.dart';
import 'bip39_currency.dart';

abstract class Bip39HDCurrency extends Bip39Currency
    implements ViewOnlyOptionCurrencyInterface {
  Bip39HDCurrency(super.network);

  coinlib.Network get networkParams;

  Amount get dustLimit;

  List<DerivePathType> get supportedDerivationPathTypes;

  String constructDerivePath({
    required DerivePathType derivePathType,
    int account = 0,
    required int chain,
    required int index,
  });

  ({coinlib.Address address, AddressType addressType}) getAddressForPublicKey({
    required coinlib.ECPublicKey publicKey,
    required DerivePathType derivePathType,
  });

  List<String> get supportedHardenedDerivationPaths {
    final paths = supportedDerivationPathTypes.map(
      (e) => (
        path: e,
        addressType: e.getAddressType(),
      ),
    );

    return paths.map((e) {
      final path = constructDerivePath(
        derivePathType: e.path,
        chain: 0,
        index: 0,
      );
      // trim unhardened
      return path.substring(0, path.lastIndexOf("'") + 1);
    }).toList();
  }
}
