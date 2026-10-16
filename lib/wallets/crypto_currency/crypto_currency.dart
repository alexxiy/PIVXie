import '../../models/isar/models/blockchain_data/address.dart';
import '../../models/node_model.dart';
import '../../utilities/enums/derive_path_type_enum.dart';

export 'coins/pivx.dart';

enum CryptoCurrencyNetwork {
  main,
  test;

  bool get isTestNet => this == CryptoCurrencyNetwork.test;
}

abstract class CryptoCurrency {
  final CryptoCurrencyNetwork network;

  CryptoCurrency(this.network);

  // Identifier should be unique.
  /// This [identifier] should also match the old `Coin` enum name for each
  /// respective coin as it is used to differentiate between coins in persistent
  /// storage.
  String get identifier;

  /// Should be the [identifier] of the main net version of the currency
  String get mainNetId;

  String get ticker;
  String get prettyName;
  String get uriScheme;

  int get minConfirms;
  int get minCoinbaseConfirms => minConfirms;

  String get genesisHash;

  bool validateAddress(String address);
  AddressType? getAddressType(String address);

  NodeModel defaultNode({required bool isPrimary});

  int get defaultSeedPhraseLength;
  int get fractionDigits;
  bool get hasBuySupport;
  bool get hasMnemonicPassphraseSupport;
  List<int> get possibleMnemonicLengths;
  AddressType get defaultAddressType;
  BigInt get satsPerCoin;
  int get targetBlockTimeSeconds;
  DerivePathType get defaultDerivePathType;

  Uri defaultBlockExplorer(String txid);

  @override
  bool operator ==(Object other) {
    return other is CryptoCurrency &&
        other.runtimeType == runtimeType &&
        other.network == network;
  }

  @override
  int get hashCode => Object.hash(runtimeType, network);
}
