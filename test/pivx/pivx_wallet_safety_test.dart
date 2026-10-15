import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/models/isar_models.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';
import 'package:paymint/wallets/models/tx_data.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_shield_state.dart';
import 'package:paymint/wallets/wallet/impl/pivx_wallet.dart';

Address _address(String value, int chain, int index) => Address(
  walletId: "w",
  value: value,
  publicKey: const [],
  derivationIndex: index,
  derivationPath: DerivationPath()..value = "m/44'/119'/0'/$chain/$index",
  type: AddressType.p2pkh,
  subType: chain == 0 ? AddressSubType.receiving : AddressSubType.change,
);

UTXO _utxo(
  String txid,
  int value, {
  bool blocked = false,
  bool? used,
  String? otherData,
}) => UTXO(
  walletId: "w",
  txid: txid,
  vout: 0,
  value: value,
  name: "",
  isBlocked: blocked,
  blockedReason: null,
  isCoinbase: false,
  blockHash: "hash",
  blockHeight: 100,
  blockTime: 1,
  used: used,
  otherData: otherData,
);

void main() {
  group("bridge address paths", () {
    test("only receiving and change paths, never hardened", () {
      expect(pivxTokenPath("m/44'/119'/0'/0/5"), (chain: 0, index: 5));
      expect(pivxTokenPath("m/44'/119'/0'/1/0"), (chain: 1, index: 0));
      expect(pivxTokenPath("m/44'/119'/0'/2/5"), isNull);
      expect(pivxTokenPath("m/44'/119'/0'/0/2147483648"), isNull);
      expect(pivxTokenPath("m/44'/119'/0'/0/5'"), isNull);
      expect(pivxTokenPath(null), isNull);
    });

    // Local derivation: "addr-<chain>-<index>".
    Future<Address> derive(int chain, int index) async =>
        _address("addr-$chain-$index", chain, index);

    test("used indices come from the wallet's own addresses", () async {
      final used = await pivxUsedAddresses(
        tokens: [
          {"name": "addr-0-3", "path": "m/44'/119'/0'/0/3"},
          {"name": "addr-1-1", "path": "m/44'/119'/0'/1/1"},
        ],
        stored: {"addr-0-0": _address("addr-0-0", 0, 0)},
        derive: derive,
      );
      expect(used.derived.map((a) => a.value), ["addr-0-3", "addr-1-1"]);
      expect((used.maxReceive, used.maxChange), (3, 1));
    });

    test("a path that doesn't derive to the address is not counted", () async {
      final used = await pivxUsedAddresses(
        tokens: [
          // A lying bridge: this address isn't at index 5000.
          {"name": "someone-else", "path": "m/44'/119'/0'/0/5000"},
        ],
        stored: const {},
        derive: derive,
      );
      expect(used.derived, isEmpty);
      expect(used.maxReceive, -1);
    });

    test("a stored address counts at its own index, whatever the path "
        "says", () async {
      final used = await pivxUsedAddresses(
        tokens: [
          {"name": "addr-0-2", "path": "m/44'/119'/0'/0/999999"},
        ],
        stored: {"addr-0-2": _address("addr-0-2", 0, 2)},
        derive: derive,
      );
      expect(used.derived, isEmpty);
      expect(used.maxReceive, 2);
    });
  });

  group("coins a send may spend", () {
    final collateral = _utxo("mn", 10000);
    final coins = [
      _utxo("a", 5),
      collateral,
      _utxo("frozen", 7, blocked: true),
      _utxo("spent", 9, used: true),
      _utxo("delegated", 3, blocked: true, otherData: '{"pivxColdStaker":"S"}'),
    ];
    List<String> spendable({bool coldStake = false, bool collateral = false}) =>
        pivxSpendable(
          coins,
          chainHeight: 200,
          minConfirms: 1,
          minCoinbaseConfirms: 101,
          collaterals: {pivxOutpointKey("mn", 0)},
          coldStake: coldStake,
          collateral: collateral,
        ).map((u) => u.txid).toList();

    test("masternode collateral only when picked, even unfrozen", () {
      expect(spendable(), ["a"]);
      expect(spendable(collateral: true), ["a", "mn"]);
      expect(spendable(coldStake: true), ["a", "delegated"]);
    });
  });

  test("shielding keys only the coins the library spends", () {
    final coins = [_utxo("c", 300000000), _utxo("a", 1000), _utxo("b", 2000)];
    // Smallest first; one coin's fee: 1000 * (150 + 34 + 2 * 948 + 85).
    const fee = 2165000;
    List<String> picked(int amount, {bool subtractFee = false}) =>
        pivxShieldingInputs(
          coins,
          amount: amount,
          toShield: true,
          subtractFee: subtractFee,
        ).map((u) => u.txid).toList();

    expect(picked(100000000), ["a", "b", "c"]);
    expect(picked(1000, subtractFee: true), ["a"]);
    expect(picked(3000, subtractFee: true), ["a", "b"]);
    expect(picked(3000), ["a", "b", "c"], reason: "fee $fee not covered");
    expect(picked(400000000), ["a", "b", "c"], reason: "never covered");
  });

  test("getbudgetvotes answers for the namesake with the most net yes", () {
    expect(pivxVotesAreFor("p1", {"p1": 5}), isTrue);
    expect(pivxVotesAreFor("p1", const {}), isTrue);
    expect(pivxVotesAreFor("p1", {"p1": 5, "p2": 3}), isTrue);
    expect(pivxVotesAreFor("p2", {"p1": 5, "p2": 3}), isFalse);
    // A tie: Core decides by its internal hash order.
    expect(pivxVotesAreFor("p1", {"p1": 5, "p2": 5}), isFalse);
  });

  test("xpubs are left out of bridge error messages", () {
    const xpub =
        "xpub6CUGRUonZSQ4TWtTMmzXdrXDtypWKiKrhko4egpiMZbpiaQL2jkwSB1icqYh2"
        "cfDfVxdx4df189oLKnC5fSwqPfgyP3hooxujYzAu3fDVmz";
    expect(
      PivxBridgeClient.redactXpubs(
        "Connection closed, uri = http://h:3000/xpub/$xpub?gap=20",
      ),
      "Connection closed, uri = http://h:3000/xpub/<xpub>?gap=20",
    );
  });

  test("change to an address outside the wallet is read back", () {
    expect(pivxForeignChange(TxData(otherData: "{}")), isNull);
    final change = pivxForeignChange(
      TxData(
        otherData: jsonEncode({
          kPivxForeignChange: {"address": "D123", "sats": "5000"},
        }),
      ),
    );
    expect(change?.address, "D123");
    expect(change?.sats, BigInt.from(5000));
  });

  test("the shield state file holds no viewing key", () {
    final state = PivxShieldState(
      extfvk: "secret-viewing-key",
      isTestnet: true,
      startHeight: 1,
      lastProcessedBlock: 2,
      commitmentTree: "00",
      diversifierIndex: const [0],
      currentAddress: "ps1",
    );
    final json = state.toJson();
    expect(jsonEncode(json), isNot(contains("secret-viewing-key")));
    final loaded = PivxShieldState.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      extfvk: "secret-viewing-key",
    );
    expect(loaded.extfvk, "secret-viewing-key");
    expect(loaded.lastProcessedBlock, 2);
  });

  test("pending shield change survives a save and load", () {
    final state = PivxShieldState(
      extfvk: "k",
      isTestnet: true,
      startHeight: 1,
      lastProcessedBlock: 2,
      commitmentTree: "00",
      diversifierIndex: const [0],
      currentAddress: "ps1",
      pendingSpent: {
        "aa": ["nf1"],
      },
      pendingIncoming: {"aa": 65202000},
    );
    final loaded = PivxShieldState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
      extfvk: "k",
    );
    expect(loaded.pendingSpent, {
      "aa": ["nf1"],
    });
    expect(loaded.pendingIncoming, {"aa": 65202000});

    // A file from before pendingIncoming existed.
    final old = state.toJson()..remove("pendingIncoming");
    final fromOld = PivxShieldState.fromJson(
      jsonDecode(jsonEncode(old)) as Map<String, dynamic>,
      extfvk: "k",
    );
    expect(fromOld.pendingIncoming, isEmpty);
  });
}
