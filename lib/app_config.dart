// ignore: unused_import
import 'dart:io';

// ignore: unused_import
import 'package:flutter/foundation.dart' show kDebugMode;

import 'wallets/crypto_currency/crypto_currency.dart';

part 'app_config.g.dart';

enum AppFeature {
  themeSelection,
  tor,

  /// Ships light and dark default themes (no theme store); settings offer
  /// System / Light / Dark.
  darkTheme,
}

abstract class AppConfig {
  static const appName = _prefix + _separator + suffix;

  static const prefix = _prefix;
  static const suffix = _suffix;

  static const emptyWalletsMessage = _emptyWalletsMessage;

  static String get appDefaultDataDirName => _appDataDirName;
  static String get shortDescriptionText => _shortDescriptionText;
  static String get commitHash => _commitHash;

  static bool hasFeature(AppFeature feature) => _features.contains(feature);

  static ({String light, String dark})? get appIconAsset => _appIconAsset;

  static List<CryptoCurrency> get coins => _supportedCoins;

  static bool get isSingleCoinApp => coins.length == 1;

  static CryptoCurrency? getCryptoCurrencyFor(String coinIdentifier) {
    try {
      return coins.firstWhere((e) => e.identifier == coinIdentifier);
    } catch (_) {
      return null;
    }
  }

  static CryptoCurrency? getCryptoCurrencyForTicker(
    String ticker, {
    bool caseInsensitive = true,
  }) {
    final _ticker = caseInsensitive ? ticker.toLowerCase() : ticker;
    try {
      return coins.firstWhere(
        caseInsensitive
            ? (e) => e.ticker.toLowerCase() == _ticker
            : (e) => e.ticker == _ticker,
      );
    } catch (_) {
      return null;
    }
  }

  static bool isStackCoin(String? ticker) {
    if (ticker == null) {
      return false;
    }

    if (getCryptoCurrencyForTicker(ticker, caseInsensitive: false) != null) {
      return true;
    }

    try {
      getCryptoCurrencyByPrettyName(ticker);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Fuzzy logic. Use with caution!!
  @Deprecated("dangerous")
  static CryptoCurrency getCryptoCurrencyByPrettyName(String prettyName) {
    const hackSplitter = " (Mainnet";
    final name = prettyName.contains(hackSplitter)
        ? prettyName.split(hackSplitter).first.toLowerCase()
        : prettyName.replaceAll(" ", "").toLowerCase();

    try {
      return coins.firstWhere(
        (e) => e.identifier.toLowerCase() == name || e.prettyName == prettyName,
      );
    } catch (_) {
      throw Exception("getCryptoCurrencyByPrettyName($prettyName) failed!");
    }
  }
}
