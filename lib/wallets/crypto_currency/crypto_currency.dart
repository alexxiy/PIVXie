import '../../models/isar/models/blockchain_data/address.dart';
import '../../models/node_model.dart';
import '../../utilities/enums/derive_path_type_enum.dart';

export 'coins/pivx.dart';

enum CryptoCurrencyNetwork {
  main,
  test,
  stage,
  test4;

  bool get isTestNet =>
      this == CryptoCurrencyNetwork.test || this == CryptoCurrencyNetwork.test4;
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

  // override in subclass if the currency has tokens on it's network
  // (used for eth currently)

  // Override in subclass if the currency has Tor support:
  bool get torSupport => false;

  int get minConfirms;
  int get minCoinbaseConfirms => minConfirms;

  // TODO: [prio=low] could be handled differently as (at least) epiccash/mimblewimblecoin does not use this
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
