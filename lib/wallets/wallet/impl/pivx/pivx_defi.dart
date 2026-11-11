part of '../pivx_wallet.dart';

// PIVXie DeFi Bridge (https://defi-bridge.pivxie.me): wrapping shielded
// PIVX into wPIVX on BNB Smart Chain and back. The bridge is a separate
// service; the wallet pays a wrap's order and keeps the orders made here.

/// Wallet otherData: the bridge orders made from this wallet, newest first.
const _kOdDefiOrders = "pivxDefiOrders";

/// How many orders a wallet keeps.
const kPivxDefiRecentMax = 20;

/// A bridge order made from this wallet. [to] and [name]: the PIVX address
/// an unwrap pays to, and the PIVX name it was found by, as the app checked
/// them (the bridge never shows a name). [paid]: a wrap's payment was sent
/// from this wallet, or the user said they paid it from another.
typedef PivxDefiRecentOrder = ({
  String id,
  String direction,
  int amount,
  int created,
  String? to,
  String? name,
  bool paid,
});

extension PivxDefiWallet on PivxWallet {
  List<PivxDefiRecentOrder> get defiOrders => _defiOrdersIn(info.otherData);

  static List<PivxDefiRecentOrder> _defiOrdersIn(Map<String, dynamic> data) {
    final stored = data[_kOdDefiOrders];
    if (stored is! List) return const [];
    return [
      for (final e in stored)
        if (e is Map &&
            e["id"] is String &&
            e["direction"] is String &&
            e["amount"] is int &&
            e["created"] is int)
          (
            id: e["id"] as String,
            direction: e["direction"] as String,
            amount: e["amount"] as int,
            created: e["created"] as int,
            to: e["to"] is String ? e["to"] as String : null,
            name: e["name"] is String ? e["name"] as String : null,
            paid: e["paid"] == true,
          ),
    ];
  }

  PivxDefiRecentOrder? defiOrder(String id) {
    for (final o in defiOrders) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// Keeps the order [id] at the top of the list. What is not given stays
  /// as it was stored.
  Future<void> rememberDefiOrder({
    required String id,
    required String direction,
    required int amount,
    required int created,
    String? to,
    String? name,
    bool? paid,
  }) => info.updateOtherDataWith(
    isar: mainDB.isar,
    change: (stored) {
      final list = _defiOrdersIn(stored);
      PivxDefiRecentOrder? old;
      for (final o in list) {
        if (o.id == id) old = o;
      }
      final entry = {
        "id": id,
        "direction": direction,
        "amount": amount,
        "created": created,
        if ((to ?? old?.to) != null) "to": to ?? old?.to,
        if ((name ?? old?.name) != null) "name": name ?? old?.name,
        if (paid ?? old?.paid ?? false) "paid": true,
      };
      return {
        _kOdDefiOrders: [
          entry,
          for (final o in list)
            if (o.id != id)
              {
                "id": o.id,
                "direction": o.direction,
                "amount": o.amount,
                "created": o.created,
                if (o.to != null) "to": o.to,
                if (o.name != null) "name": o.name,
                if (o.paid) "paid": true,
              },
        ].take(kPivxDefiRecentMax).toList(),
      };
    },
  );

  /// Marks a wrap's payment as sent (or not, to show the payment details
  /// again).
  Future<void> setDefiOrderPaid(String id, bool paid) async {
    final o = defiOrder(id);
    if (o == null || o.paid == paid) return;
    await info.updateOtherDataWith(
      isar: mainDB.isar,
      change: (stored) => {
        _kOdDefiOrders: [
          for (final e in (stored[_kOdDefiOrders] as List?) ?? const [])
            if (e is Map && e["id"] == id)
              {
                for (final kv in e.entries)
                  if (kv.key != "paid") kv.key: kv.value,
                if (paid) "paid": true,
              }
            else
              e,
        ],
      },
    );
  }

  /// The payment of a wrap order: [amount] to the bridge's shield
  /// [address], with the order's [memo] (`<order id>:<BSC address>`), paid
  /// as [funding] says. The fee comes on top: the bridge wants the exact
  /// amount of the order.
  Future<TxData> prepareDefiWrapPayment({
    required String address,
    required Amount amount,
    required String memo,
    required String note,
    PivxFunding funding = kPivxAutoFunding,
  }) {
    if (!isShieldAddress(address)) {
      throw Exception(l10n.defiNotShieldAddress);
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
}
