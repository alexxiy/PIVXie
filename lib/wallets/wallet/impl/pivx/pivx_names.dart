part of '../pivx_wallet.dart';

// PIVX.name (https://pivx.name): registering and managing names. A
// command is a payment to the registrar's shield address whose memo is
// the command, signed with the wallet's names key.

/// Wallet otherData: the PIVX.name payments sent from this wallet, kept
/// until the registrar lists them, so that they show in My Transactions
/// right away.
const _kOdNamesSent = "pivxNamesSent";

/// How long a sent payment is shown without the registrar listing it.
const _kNamesSentMaxAge = Duration(days: 3);

/// A PIVX.name payment sent from this wallet.
typedef PivxNamesSent = ({
  String txid,
  String name,
  String op,
  String memo,
  DateTime sent,
});

extension PivxNamesWallet on PivxWallet {
  /// The key of this wallet's names: the same key pivx.name makes from
  /// this wallet's recovery phrase.
  Future<PivxNamesIdentity> namesIdentity() async =>
      PivxNamesIdentity.fromMnemonic(await getMnemonic());

  /// The payment of a PIVX.name command: [amount] to the registrar's
  /// [address], with the command as the shielded memo, paid as [funding]
  /// says. The fee comes on top (the registrar wants the exact price).
  Future<TxData> prepareNamesPayment({
    required String address,
    required Amount amount,
    required String memo,
    required String note,
    PivxFunding funding = kPivxAutoFunding,
  }) {
    if (!isShieldAddress(address)) {
      throw Exception(l10n.namesNotShieldAddress);
    }
    return prepareSend(
      txData: TxData(
        note: note,
        noteOnChain: "",
        memo: memo,
        recipients: [
          TxRecipient(
            address: address,
            amount: amount,
            isChange: false,
            addressType: AddressType.pivxShield,
          ),
        ],
        utxos: pivxFundingInputs(funding),
        otherData: jsonEncode(pivxFundingOtherData(funding)),
      ),
    );
  }

  /// This wallet's shield addresses, newest first.
  Future<List<Address>> ownShieldAddresses() => mainDB
      .getAddresses(walletId)
      .filter()
      .typeEqualTo(AddressType.pivxShield)
      .sortByDerivationIndexDesc()
      .findAll();

  /// The PIVX.name payments sent from this wallet that may not be listed
  /// by the registrar yet, newest first.
  List<PivxNamesSent> get namesSent {
    final stored = info.otherData[_kOdNamesSent];
    if (stored is! List) return const [];
    final now = DateTime.now();
    final out = <PivxNamesSent>[];
    for (final e in stored) {
      if (e is! Map) continue;
      final sent = DateTime.fromMillisecondsSinceEpoch(
        ((e["sent"] as num?) ?? 0).toInt() * 1000,
      );
      if (now.difference(sent) > _kNamesSentMaxAge) continue;
      out.add((
        txid: "${e["txid"]}",
        name: "${e["name"]}",
        op: "${e["op"]}",
        memo: "${e["memo"]}",
        sent: sent,
      ));
    }
    out.sort((a, b) => b.sent.compareTo(a.sent));
    return out;
  }

  /// Remembers [sent] (right before it is broadcast).
  Future<void> rememberNamesSent(PivxNamesSent sent) =>
      info.updateOtherDataWith(
        isar: mainDB.isar,
        change: (stored) => {
          _kOdNamesSent: [
            for (final e in (stored[_kOdNamesSent] as List?) ?? const [])
              if (e is Map && e["txid"] != sent.txid) e,
            {
              "txid": sent.txid,
              "name": sent.name,
              "op": sent.op,
              "memo": sent.memo,
              "sent": sent.sent.millisecondsSinceEpoch ~/ 1000,
            },
          ],
        },
      );

  /// Forgets the payments [txids] (listed by the registrar now, or never
  /// sent), and the ones too old to show.
  Future<void> forgetNamesSent(Iterable<String> txids) {
    final drop = txids.toSet();
    final keep = namesSent.map((e) => e.txid).toSet().difference(drop);
    return info.updateOtherDataWith(
      isar: mainDB.isar,
      change: (stored) => {
        _kOdNamesSent: [
          for (final e in (stored[_kOdNamesSent] as List?) ?? const [])
            if (e is Map && keep.contains(e["txid"])) e,
        ],
      },
    );
  }
}
