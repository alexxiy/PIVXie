import 'package:isar_community/isar.dart';

part 'output_v2.g.dart';

@Embedded()
class OutputV2 {
  late final String scriptPubKeyHex;
  late final String? scriptPubKeyAsm;
  late final String valueStringSats;
  late final List<String> addresses;

  late final bool walletOwns;

  @ignore
  BigInt get value => BigInt.parse(valueStringSats);

  OutputV2();

  static OutputV2 isarCantDoRequiredInDefaultConstructor({
    required String scriptPubKeyHex,
    String? scriptPubKeyAsm,
    required String valueStringSats,
    required List<String> addresses,
    required bool walletOwns,
  }) =>
      OutputV2()
        ..scriptPubKeyHex = scriptPubKeyHex
        ..scriptPubKeyAsm = scriptPubKeyAsm
        ..valueStringSats = valueStringSats
        ..walletOwns = walletOwns
        ..addresses = List.unmodifiable(addresses);

  OutputV2 copyWith({
    String? scriptPubKeyHex,
    String? scriptPubKeyAsm,
    String? valueStringSats,
    List<String>? addresses,
    bool? walletOwns,
  }) {
    return OutputV2.isarCantDoRequiredInDefaultConstructor(
      scriptPubKeyHex: scriptPubKeyHex ?? this.scriptPubKeyHex,
      scriptPubKeyAsm: scriptPubKeyAsm ?? this.scriptPubKeyAsm,
      valueStringSats: valueStringSats ?? this.valueStringSats,
      addresses: addresses ?? this.addresses,
      walletOwns: walletOwns ?? this.walletOwns,
    );
  }

  @override
  String toString() {
    return 'OutputV2(\n'
        '  scriptPubKeyHex: $scriptPubKeyHex,\n'
        '  scriptPubKeyAsm: $scriptPubKeyAsm,\n'
        '  value: $value,\n'
        '  walletOwns: $walletOwns,\n'
        '  addresses: $addresses,\n'
        ')';
  }
}
