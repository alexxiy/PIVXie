import 'dart:convert';

import 'key_data_interface.dart';

// do not remove or change the order of these enum values
enum ViewOnlyWalletType {
  cryptonote,
  addressOnly,
  xPub,
  spark,
  saplingViewingKey,
}

class XPub {
  XPub({required this.path, required this.encoded});

  final String path;
  final String encoded;

  @override
  String toString() => "XPub { path: $path, encoded: $encoded }";
}

sealed class ViewOnlyWalletData with KeyDataInterface {
  @override
  final String walletId;

  ViewOnlyWalletType get type;

  ViewOnlyWalletData({required this.walletId});

  static ViewOnlyWalletData fromJsonEncodedString(
    String jsonEncodedString, {
    required String walletId,
  }) {
    final map = jsonDecode(jsonEncodedString) as Map;
    final json = Map<String, dynamic>.from(map);
    final type = ViewOnlyWalletType.values[json["type"] as int];

    switch (type) {
      case ViewOnlyWalletType.addressOnly:
        return AddressViewOnlyWalletData.fromJsonEncodedString(
          jsonEncodedString,
          walletId: walletId,
        );

      case ViewOnlyWalletType.xPub:
        return ExtendedKeysViewOnlyWalletData.fromJsonEncodedString(
          jsonEncodedString,
          walletId: walletId,
        );

      case ViewOnlyWalletType.saplingViewingKey:
        return SaplingViewingKeyViewOnlyWalletData.fromJsonEncodedString(
          jsonEncodedString,
          walletId: walletId,
        );

      case ViewOnlyWalletType.cryptonote:
      case ViewOnlyWalletType.spark:
        throw UnsupportedError("$type view only wallets are not supported");
    }
  }

  String toJsonEncodedString();
}

class AddressViewOnlyWalletData extends ViewOnlyWalletData {
  @override
  final type = ViewOnlyWalletType.addressOnly;

  final String address;

  AddressViewOnlyWalletData({required super.walletId, required this.address});

  static AddressViewOnlyWalletData fromJsonEncodedString(
    String jsonEncodedString, {
    required String walletId,
  }) {
    final map = jsonDecode(jsonEncodedString) as Map;
    final json = Map<String, dynamic>.from(map);

    return AddressViewOnlyWalletData(
      walletId: walletId,
      address: json["address"] as String,
    );
  }

  @override
  String toJsonEncodedString() =>
      jsonEncode({"type": type.index, "address": address});
}

class ExtendedKeysViewOnlyWalletData extends ViewOnlyWalletData {
  @override
  final type = ViewOnlyWalletType.xPub;

  final List<XPub> xPubs;

  ExtendedKeysViewOnlyWalletData({
    required super.walletId,
    required List<XPub> xPubs,
  }) : xPubs = List.unmodifiable(xPubs);

  static ExtendedKeysViewOnlyWalletData fromJsonEncodedString(
    String jsonEncodedString, {
    required String walletId,
  }) {
    final map = jsonDecode(jsonEncodedString) as Map;
    final json = Map<String, dynamic>.from(map);

    return ExtendedKeysViewOnlyWalletData(
      walletId: walletId,
      xPubs: List<Map<String, dynamic>>.from((json["xPubs"] as List))
          .map(
            (e) => XPub(
              path: e["path"] as String,
              encoded: e["encoded"] as String,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  String toJsonEncodedString() => jsonEncode({
    "type": type.index,
    "xPubs": [
      ...xPubs.map((e) => {"path": e.path, "encoded": e.encoded}),
    ],
  });
}

/// Watches the shield (Sapling) addresses of an extended full viewing key,
/// as PIVX Core's `exportsaplingviewingkey` gives it: e.g. a service that
/// publishes its key so anyone can check its shield transactions.
class SaplingViewingKeyViewOnlyWalletData extends ViewOnlyWalletData {
  @override
  final type = ViewOnlyWalletType.saplingViewingKey;

  final String viewingKey;

  SaplingViewingKeyViewOnlyWalletData({
    required super.walletId,
    required this.viewingKey,
  });

  static SaplingViewingKeyViewOnlyWalletData fromJsonEncodedString(
    String jsonEncodedString, {
    required String walletId,
  }) {
    final map = jsonDecode(jsonEncodedString) as Map;
    final json = Map<String, dynamic>.from(map);

    return SaplingViewingKeyViewOnlyWalletData(
      walletId: walletId,
      viewingKey: json["viewingKey"] as String,
    );
  }

  @override
  String toJsonEncodedString() =>
      jsonEncode({"type": type.index, "viewingKey": viewingKey});
}
