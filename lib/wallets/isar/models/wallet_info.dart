import 'dart:convert';

import 'package:isar_community/isar.dart';
import 'package:uuid/uuid.dart';

import '../../../app_config.dart';
import '../../../models/balance.dart';
import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../models/keys/view_only_wallet_data.dart';
import '../../crypto_currency/crypto_currency.dart';
import '../isar_id_interface.dart';
import 'wallet_info_meta.dart';

part 'wallet_info.g.dart';

@Collection(accessor: "walletInfo", inheritance: false)
class WalletInfo implements IsarId {
  @override
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: false)
  final String walletId;

  final String name;

  @enumerated
  final AddressType mainAddressType;

  /// The highest index [mainAddressType] receiving address of the wallet
  final String cachedReceivingAddress;

  /// Only exposed for Isar. Use the [cachedBalance] getter.
  // Only exposed for isar as Amount cannot be stored in isar easily
  final String? cachedBalanceString;

  /// Only exposed for Isar. Use the [cachedBalanceSecondary] getter.
  // Only exposed for isar as Amount cannot be stored in isar easily
  final String? cachedBalanceSecondaryString;

  /// Only exposed for Isar. Use the [coin] getter.
  // Only exposed for isar to avoid dealing with storing enums as Coin can change
  final String coinName;

  /// User set favourites ordering. No restrictions are placed on uniqueness.
  /// Reordering logic in the ui code should ensure this is unique.
  ///
  /// Also represents if the wallet is a favourite. Any number greater then -1
  /// denotes a favourite. Any number less than 0 means it is not a favourite.
  final int favouriteOrderIndex;

  /// The highest block height the wallet has scanned.
  final int cachedChainHeight;

  /// The block at which this wallet was or should be restored from
  final int restoreHeight;

  final String? otherDataJsonString;

  //============================================================================
  //=============== Getters ====================================================

  bool get isFavourite => favouriteOrderIndex > -1;

  /// The shield balance.
  @ignore
  Balance get cachedBalanceSecondary {
    if (cachedBalanceSecondaryString == null) {
      return Balance.zeroFor(currency: coin);
    } else {
      return Balance.fromJson(
        cachedBalanceSecondaryString!,
        coin.fractionDigits,
      );
    }
  }

  @ignore
  CryptoCurrency get coin => AppConfig.getCryptoCurrencyFor(coinName)!;

  @ignore
  Balance get cachedBalance {
    if (cachedBalanceString == null) {
      return Balance.zeroFor(currency: coin);
    } else {
      return Balance.fromJson(cachedBalanceString!, coin.fractionDigits);
    }
  }

  @ignore
  Map<String, dynamic> get otherData => otherDataJsonString == null
      ? {}
      : Map<String, dynamic>.from(jsonDecode(otherDataJsonString!) as Map);

  @ignore
  bool get isViewOnly =>
      otherData[WalletInfoKeys.isViewOnlyKey] as bool? ?? false;

  @ignore
  ViewOnlyWalletType? get viewOnlyWalletType {
    final index = otherData[WalletInfoKeys.viewOnlyTypeIndexKey] as int?;
    if (index == null) return null;
    return ViewOnlyWalletType.values[index];
  }

  Future<bool> isMnemonicVerified(Isar isar) async =>
      (await isar.walletInfoMeta.where().walletIdEqualTo(walletId).findFirst())
          ?.isMnemonicVerified ==
      true;

  @ignore
  bool get isDuressVisible =>
      otherData[WalletInfoKeys.duressMarkedVisibleWalletKey] as bool? ?? false;

  //============================================================================
  //=============    Updaters   ================================================

  Future<void> updateDuressVisibilityStatus({
    required bool isDuressVisible,
    required Isar isar,
  }) async {
    await updateOtherData(
      newEntries: {
        WalletInfoKeys.duressMarkedVisibleWalletKey: isDuressVisible,
      },
      isar: isar,
    );
  }

  /// Replace the stored copy of this wallet with [change] of it, reading
  /// and writing in one transaction: updates running at the same time
  /// (a balance during a sync, an otherData entry from the UI) can't
  /// overwrite each other with an older copy. [change] returns null when
  /// there is nothing to update.
  Future<void> _updateStored(
    Isar isar,
    WalletInfo? Function(WalletInfo stored) change,
  ) => isar.writeTxn(() async {
    final stored = await isar.walletInfo.get(id) ?? this;
    final updated = change(stored);
    if (updated == null) return;
    await isar.walletInfo.delete(stored.id);
    await isar.walletInfo.put(updated);
  });

  Future<void> updateBalance({
    required Balance newBalance,
    required Isar isar,
  }) {
    final newEncoded = newBalance.toJsonIgnoreCoin();
    return _updateStored(
      isar,
      (stored) => stored.cachedBalanceString == newEncoded
          ? null
          : stored.copyWith(cachedBalanceString: newEncoded),
    );
  }

  Future<void> updateBalanceSecondary({
    required Balance newBalance,
    required Isar isar,
  }) {
    final newEncoded = newBalance.toJsonIgnoreCoin();
    return _updateStored(
      isar,
      (stored) => stored.cachedBalanceSecondaryString == newEncoded
          ? null
          : stored.copyWith(cachedBalanceSecondaryString: newEncoded),
    );
  }

  /// copies this with a new chain height and updates the db
  Future<void> updateCachedChainHeight({
    required int newHeight,
    required Isar isar,
  }) => _updateStored(
    isar,
    (stored) => stored.cachedChainHeight == newHeight
        ? null
        : stored.copyWith(cachedChainHeight: newHeight),
  );

  /// update favourite wallet and its index it the ui list.
  /// When [customIndexOverride] is not null the [flag] will be ignored.
  Future<void> updateIsFavourite(
    bool flag, {
    required Isar isar,
    int? customIndexOverride,
  }) async {
    final int index;

    if (customIndexOverride != null) {
      index = customIndexOverride;
    } else if (flag) {
      final highest = await isar.walletInfo
          .where()
          .sortByFavouriteOrderIndexDesc()
          .favouriteOrderIndexProperty()
          .findFirst();
      index = (highest ?? 0) + 1;
    } else {
      index = -1;
    }

    await _updateStored(
      isar,
      (stored) => stored.favouriteOrderIndex == index
          ? null
          : stored.copyWith(favouriteOrderIndex: index),
    );
  }

  /// copies this with a new name and updates the db
  Future<void> updateName({required String newName, required Isar isar}) async {
    // don't allow empty names
    if (newName.isEmpty) {
      throw Exception("Empty wallet name not allowed!");
    }

    await _updateStored(
      isar,
      (stored) =>
          stored.name == newName ? null : stored.copyWith(name: newName),
    );
  }

  /// copies this with a new name and updates the db
  Future<void> updateReceivingAddress({
    required String newAddress,
    required Isar isar,
  }) => _updateStored(
    isar,
    (stored) => stored.cachedReceivingAddress == newAddress
        ? null
        : stored.copyWith(cachedReceivingAddress: newAddress),
  );

  /// update [otherData] with the map entries in [newEntries]
  Future<void> updateOtherData({
    required Map<String, dynamic> newEntries,
    required Isar isar,
  }) => updateOtherDataWith(isar: isar, change: (_) => newEntries);

  /// Update [otherData] with the entries [change] returns for the stored
  /// otherData, e.g. a list rebuilt from its stored value.
  Future<void> updateOtherDataWith({
    required Map<String, dynamic> Function(Map<String, dynamic> stored) change,
    required Isar isar,
  }) => _updateStored(isar, (stored) {
    final newMap = {...stored.otherData, ...change(stored.otherData)};
    final encodedNew = jsonEncode(newMap);
    // only update if there were changes
    return stored.otherDataJsonString == encodedNew
        ? null
        : stored.copyWith(otherDataJsonString: encodedNew);
  });

  /// Can be dangerous. Don't use unless you know the consequences
  Future<void> setMnemonicVerified({required Isar isar}) async {
    final meta = await isar.walletInfoMeta
        .where()
        .walletIdEqualTo(walletId)
        .findFirst();
    if (meta == null) {
      await isar.writeTxn(() async {
        await isar.walletInfoMeta.put(
          WalletInfoMeta(walletId: walletId, isMnemonicVerified: true),
        );
      });
    } else if (meta.isMnemonicVerified == false) {
      await isar.writeTxn(() async {
        await isar.walletInfoMeta.deleteByWalletId(walletId);
        await isar.walletInfoMeta.put(
          WalletInfoMeta(walletId: walletId, isMnemonicVerified: true),
        );
      });
    } else {
      throw Exception(
        "setMnemonicVerified() called on already"
        " verified wallet: $name, $walletId",
      );
    }
  }

  /// copies this with a new name and updates the db
  Future<void> updateRestoreHeight({
    required int newRestoreHeight,
    required Isar isar,
  }) async {
    // don't allow empty names
    if (newRestoreHeight < 0) {
      throw Exception("Negative restore height not allowed!");
    }

    await _updateStored(
      isar,
      (stored) => stored.restoreHeight == newRestoreHeight
          ? null
          : stored.copyWith(restoreHeight: newRestoreHeight),
    );
  }

  //============================================================================

  WalletInfo({
    required this.walletId,
    required this.name,
    required this.mainAddressType,
    required this.coinName,

    // cachedReceivingAddress should never actually be empty in practice as
    // on wallet init it will be set
    this.cachedReceivingAddress = "",
    this.favouriteOrderIndex = -1,
    this.cachedChainHeight = 0,
    this.restoreHeight = 0,
    this.cachedBalanceString,
    this.cachedBalanceSecondaryString,
    this.otherDataJsonString,
  }) : assert(AppConfig.coins.map((e) => e.identifier).contains(coinName));

  WalletInfo copyWith({
    String? name,
    AddressType? mainAddressType,
    String? cachedReceivingAddress,
    String? cachedBalanceString,
    String? cachedBalanceSecondaryString,
    String? coinName,
    int? favouriteOrderIndex,
    int? cachedChainHeight,
    int? restoreHeight,
    String? otherDataJsonString,
  }) {
    return WalletInfo(
      walletId: walletId,
      name: name ?? this.name,
      mainAddressType: mainAddressType ?? this.mainAddressType,
      cachedReceivingAddress:
          cachedReceivingAddress ?? this.cachedReceivingAddress,
      cachedBalanceString: cachedBalanceString ?? this.cachedBalanceString,
      cachedBalanceSecondaryString:
          cachedBalanceSecondaryString ?? this.cachedBalanceSecondaryString,
      coinName: coinName ?? this.coinName,
      favouriteOrderIndex: favouriteOrderIndex ?? this.favouriteOrderIndex,
      cachedChainHeight: cachedChainHeight ?? this.cachedChainHeight,
      restoreHeight: restoreHeight ?? this.restoreHeight,
      otherDataJsonString: otherDataJsonString ?? this.otherDataJsonString,
    )..id = id;
  }

  static WalletInfo createNew({
    required CryptoCurrency coin,
    required String name,
    int restoreHeight = 0,
    String? walletIdOverride,
    String? otherDataJsonString,
  }) {
    return WalletInfo(
      coinName: coin.identifier,
      walletId: walletIdOverride ?? const Uuid().v1(),
      name: name,
      mainAddressType: coin.defaultAddressType,
      restoreHeight: restoreHeight,
      otherDataJsonString: otherDataJsonString,
    );
  }

  @override
  String toString() => "WalletInfo: $name ($walletId, ${coin.identifier})";
}

abstract class WalletInfoKeys {
  static const String reuseAddress = "reuseAddressKey";
  static const String isViewOnlyKey = "isViewOnlyKey";
  static const String viewOnlyTypeIndexKey = "viewOnlyTypeIndexKey";
  static const String duressMarkedVisibleWalletKey =
      "duressMarkedVisibleWalletKey";
}
