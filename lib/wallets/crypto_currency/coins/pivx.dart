import 'dart:typed_data';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;

import '../../../models/coinlib/exp2pkh_address.dart';
import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../models/node_model.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/default_nodes.dart';
import '../../../utilities/enums/derive_path_type_enum.dart';
import '../../../wl_gen/interfaces/lib_pivx_shield_interface.dart';
import '../crypto_currency.dart';
import '../intermediate/bip39_hd_currency.dart';

/// PIVX. Chain parameters follow PIVX Core `src/chainparams.cpp` (v5.6.1);
/// wallet behaviour follows MyPIVXWallet (BIP44 coin type 119, 12-word
/// seeds, 10 sat/byte fees).
///
/// Network data comes from a pivx-bridge instance (shield stream + RPC
/// proxy + transparent address index), configured as
/// this coin's node: `host` is the full base URL, e.g.
/// `https://rpc.example.org/mainnet`.
///
/// [CryptoCurrencyNetwork.test] covers both PIVX testnet and regtest,
/// which share address/key prefixes.
class Pivx extends Bip39HDCurrency {
  Pivx(super.network) {
    _idMain = "pivx";
    _uriScheme = "pivx";
    switch (network) {
      case CryptoCurrencyNetwork.main:
        _id = _idMain;
        _name = "PIVX";
        _ticker = "PIV";
      case CryptoCurrencyNetwork.test:
        _id = "pivxTestNet";
        _name = "tPIVX";
        _ticker = "tPIV";
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  late final String _id;
  @override
  String get identifier => _id;

  late final String _idMain;
  @override
  String get mainNetId => _idMain;

  late final String _name;
  @override
  String get prettyName => _name;

  late final String _uriScheme;
  @override
  String get uriScheme => _uriScheme;

  late final String _ticker;
  @override
  String get ticker => _ticker;

  @override
  int get minConfirms => 1;

  /// Coinbase and coinstake outputs mature after 100 blocks
  /// (spendable at 101 confirmations). Regtest also uses 100, so the
  /// stricter value is used for the shared test network.
  @override
  int get minCoinbaseConfirms => 101;

  @override
  bool get torSupport => true;

  @override
  List<DerivePathType> get supportedDerivationPathTypes => [
    DerivePathType.bip44,
  ];

  /// Genesis hashes of the networks a node may serve. Testnet and
  /// regtest both map to [CryptoCurrencyNetwork.test].
  List<String> get acceptedGenesisHashes {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        return [genesisHash];
      case CryptoCurrencyNetwork.test:
        return [
          genesisHash,
          // regtest
          "7445589c4c8e52b105247b13373e5ee325856aa05d53f429e59ea46b7149ae3f",
        ];
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  @override
  String get genesisHash {
    switch (network) {
      case CryptoCurrencyNetwork.main:
      case CryptoCurrencyNetwork.test:
        // PIVX testnet reuses the mainnet genesis block.
        return "0000041e482b9b9691d98eefb48473405c0b8ec31b76df3797c74a78680ef818";
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  /// PIVX Core's dust threshold at the default 10 sat/byte relay fee:
  /// 3 * (34 + 148) bytes * 10 sat/byte.
  @override
  Amount get dustLimit =>
      Amount(rawValue: BigInt.from(5460), fractionDigits: fractionDigits);

  /// Minimum relay fee (sat per byte). MyPIVXWallet always pays this.
  int get minFeePerByte => 10;

  /// Exchange address (`EXM…` / `EXT…`) version bytes.
  Uint8List get exAddressVersion {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        return Uint8List.fromList([0x01, 0xb9, 0xa2]);
      case CryptoCurrencyNetwork.test:
        return Uint8List.fromList([0x01, 0xb9, 0xb1]);
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  /// Masternode payment of a block at [height] (unknown: the current
  /// one): 6 PIV since the v5.5 upgrade, 3 PIV before (PIVX Core's
  /// nNewMNBlockReward / nMNBlockReward).
  BigInt masternodePaymentAt(int? height) {
    final v55 = switch (network) {
      CryptoCurrencyNetwork.main => 3715200,
      // Testnet; regtest activates it at 576.
      _ => 650,
    };
    final coins = height != null && height < v55 ? 3 : 6;
    return BigInt.from(coins) * BigInt.from(10).pow(fractionDigits);
  }

  /// Cold staking address version byte (`S…` / `W…`).
  int get stakingAddressPrefix {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        return 63;
      case CryptoCurrencyNetwork.test:
        return 73;
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  /// Sapling shield address human-readable part.
  String get shieldHrp {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        return "ps";
      case CryptoCurrencyNetwork.test:
        return "ptestsapling";
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  @override
  coinlib.Network get networkParams {
    // Extended keys use the Bitcoin `xpub`/`tpub` serialisation, like
    // MyPIVXWallet, so exported xpubs are interchangeable between the two.
    switch (network) {
      case CryptoCurrencyNetwork.main:
        return coinlib.Network(
          wifPrefix: 212,
          p2pkhPrefix: 30,
          p2shPrefix: 13,
          privHDPrefix: 0x0488ade4,
          pubHDPrefix: 0x0488b21e,
          bech32Hrp: "ps",
          messagePrefix: "\x18DarkNet Signed Message:\n",
          minFee: BigInt.from(10000),
          minOutput: dustLimit.raw,
          feePerKb: BigInt.from(10000),
        );
      case CryptoCurrencyNetwork.test:
        return coinlib.Network(
          wifPrefix: 239,
          p2pkhPrefix: 139,
          p2shPrefix: 19,
          privHDPrefix: 0x04358394,
          pubHDPrefix: 0x043587cf,
          bech32Hrp: "ptestsapling",
          messagePrefix: "\x18DarkNet Signed Message:\n",
          minFee: BigInt.from(10000),
          minOutput: dustLimit.raw,
          feePerKb: BigInt.from(10000),
        );
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  @override
  String constructDerivePath({
    required DerivePathType derivePathType,
    int account = 0,
    required int chain,
    required int index,
  }) {
    final String coinType;
    switch (network) {
      case CryptoCurrencyNetwork.main:
        coinType = "119";
      case CryptoCurrencyNetwork.test:
        coinType = "1";
      default:
        throw Exception("Unsupported network: $network");
    }

    switch (derivePathType) {
      case DerivePathType.bip44:
        return "m/44'/$coinType'/$account'/$chain/$index";
      default:
        throw Exception("DerivePathType $derivePathType not supported");
    }
  }

  @override
  ({coinlib.Address address, AddressType addressType}) getAddressForPublicKey({
    required coinlib.ECPublicKey publicKey,
    required DerivePathType derivePathType,
  }) {
    switch (derivePathType) {
      case DerivePathType.bip44:
        final addr = coinlib.P2PKHAddress.fromPublicKey(
          publicKey,
          version: networkParams.p2pkhPrefix,
        );
        return (address: addr, addressType: AddressType.p2pkh);
      default:
        throw Exception("DerivePathType $derivePathType not supported");
    }
  }

  @override
  bool validateAddress(String address) {
    return isTransparentAddress(address) ||
        isExchangeAddress(address) ||
        isShieldAddress(address);
  }

  /// Sapling address (`ps1…` / `ptestsapling1…`). Needs the shield
  /// library; without it shield addresses are rejected.
  bool isShieldAddress(String address) {
    if (!address.startsWith(shieldHrp)) return false;
    return libPivxShield.isAvailable &&
        libPivxShield.isValidAddress(
          address,
          isTestnet: network != CryptoCurrencyNetwork.main,
        );
  }

  bool isTransparentAddress(String address) {
    try {
      final a = coinlib.Address.fromString(address, networkParams);
      return a is coinlib.P2PKHAddress || a is coinlib.P2SHAddress;
    } catch (_) {
      return false;
    }
  }

  bool isExchangeAddress(String address) {
    try {
      EXP2PKHAddress.fromString(address, exAddressVersion);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  AddressType? getAddressType(String address) {
    if (isExchangeAddress(address)) return AddressType.p2pkh;
    if (isShieldAddress(address)) return AddressType.pivxShield;
    try {
      final a = coinlib.Address.fromString(address, networkParams);
      if (a is coinlib.P2PKHAddress) return AddressType.p2pkh;
      if (a is coinlib.P2SHAddress) return AddressType.p2sh;
    } catch (_) {}
    return null;
  }

  @override
  NodeModel defaultNode({required bool isPrimary}) {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        // TODO: switch to the public bridge URL once it runs with
        // ADDR_INDEX enabled. Development bridge for now.
        return NodeModel(
          host: "http://192.168.1.100:3000",
          port: 3000,
          name: DefaultNodes.defaultName,
          id: DefaultNodes.buildId(this),
          useSSL: false,
          enabled: true,
          coinName: identifier,
          isFailover: true,
          isDown: false,
          torEnabled: true,
          clearnetEnabled: true,
          isPrimary: isPrimary,
        );
      case CryptoCurrencyNetwork.test:
        return NodeModel(
          host: "http://192.168.1.27:3000",
          port: 3000,
          name: DefaultNodes.defaultName,
          id: DefaultNodes.buildId(this),
          useSSL: false,
          enabled: true,
          coinName: identifier,
          isFailover: true,
          isDown: false,
          torEnabled: true,
          clearnetEnabled: true,
          isPrimary: isPrimary,
        );
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  @override
  int get defaultSeedPhraseLength => 12;

  @override
  int get fractionDigits => 8;

  @override
  bool get hasBuySupport => false;

  @override
  bool get hasMnemonicPassphraseSupport => true;

  @override
  List<int> get possibleMnemonicLengths => [defaultSeedPhraseLength, 24];

  @override
  AddressType get defaultAddressType => defaultDerivePathType.getAddressType();

  @override
  BigInt get satsPerCoin => BigInt.from(100000000);

  @override
  int get targetBlockTimeSeconds => 60;

  @override
  DerivePathType get defaultDerivePathType => DerivePathType.bip44;

  @override
  Uri defaultBlockExplorer(String txid) {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        return Uri.parse("https://explorer.pivx.org/#/tx/$txid");
      case CryptoCurrencyNetwork.test:
        return Uri.parse("https://testnet.rockdev.org/tx/$txid");
      default:
        throw Exception(
          "Unsupported network for defaultBlockExplorer(): $network",
        );
    }
  }
}
