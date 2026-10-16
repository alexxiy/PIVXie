import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/transaction_filter.dart';
import 'package:paymint/models/isar/models/blockchain_data/transaction_type.dart';
import 'package:paymint/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_tx_parser.dart';

const _coin = 100000000;

// Addresses of a regtest coinstake (block 6275): our delegation staked
// and the block's masternode payment went to our masternode.
const _staker = "WhPFBAdcR6aVW55u5zR4JTnkg4tiQtGUKn";
const _owner = "xwyKYcujb84bWDgAnnLfQjQvuFTjtCa8DE";
const _masternode = "xzLMdk2BHfYkiy5QxA7z5cHJPGoFoCVteh";
const _someone = "y5zjsJx6ABcCAuQkSjLWjL948Jnfa3unXe";

final _p2cs = "76a97b63d114${"11" * 20}6714${"22" * 20}6888ac";
final _p2pkh = "76a914${"33" * 20}88ac";

Map<String, dynamic> _coinstake({
  required List<String> inputAddresses,
  required int inputValue,
  required List<Map<String, dynamic>> payments,
}) => {
  "txid": "aa" * 32,
  "blockHeight": 6275,
  "blockTime": 1791743701,
  "coinstake": true,
  "coinbase": false,
  "fees": "0",
  "vin": [
    {
      "txid": "bb" * 32,
      "vout": 0,
      "addresses": inputAddresses,
      "value": "$inputValue",
    },
  ],
  "vout": [
    {"value": "0", "addresses": <String>[], "hex": ""},
    ...payments,
  ],
};

void main() {
  final coin = Pivx(CryptoCurrencyNetwork.test);

  TransactionV2 parse(Map<String, dynamic> json, Set<String> ours) =>
      parsePivxTx(
        json,
        walletId: "test",
        fractionDigits: 8,
        receiving: ours,
        change: const {},
        shieldAddresses: const {},
        masternodePayment: coin.masternodePaymentAt,
      )!;

  BigInt amount(TransactionV2 tx) =>
      tx.getAmountReceivedInThisWallet(fractionDigits: 8).raw;

  test("masternode payment by height", () {
    final main = Pivx(CryptoCurrencyNetwork.main);
    expect(main.masternodePaymentAt(3715199), BigInt.from(3 * _coin));
    expect(main.masternodePaymentAt(3715200), BigInt.from(6 * _coin));
    expect(main.masternodePaymentAt(null), BigInt.from(6 * _coin));
    expect(coin.masternodePaymentAt(6275), BigInt.from(6 * _coin));
  });

  test("a cold stake that also paid our masternode", () {
    final delegated = 499997470;
    final tx = parse(
      _coinstake(
        inputAddresses: [_staker, _owner],
        inputValue: delegated,
        payments: [
          {
            "value": "${delegated + 4 * _coin}",
            "addresses": [_staker, _owner],
            "hex": _p2cs,
          },
          {
            "value": "${6 * _coin}",
            "addresses": [_masternode],
            "hex": _p2pkh,
          },
        ],
      ),
      {_owner, _masternode},
    );
    // Like PIVX Core: all the block paid us, 4 PIV staking + 6 PIV
    // masternode.
    expect(tx.pivxKind, PivxTxKind.coldStakeReward);
    expect(tx.type, TransactionType.incoming);
    expect(amount(tx), BigInt.from(10 * _coin));
    expect(tx.pivxAlsoKind, PivxTxKind.masternodeReward);
    expect(tx.pivxAlsoLabel, "Masternode reward");
    expect(
      PivxTxCategory.allOf(tx),
      {PivxTxCategory.coldStakingReward, PivxTxCategory.masternodeReward},
    );
  });

  test("a cold stake in the superblock that paid our proposal", () {
    final delegated = 499997470;
    final tx = parse(
      _coinstake(
        inputAddresses: [_staker, _owner],
        inputValue: delegated,
        payments: [
          {
            "value": "${delegated + 4 * _coin}",
            "addresses": [_staker, _owner],
            "hex": _p2cs,
          },
          {
            "value": "${500 * _coin}",
            "addresses": [_masternode],
            "hex": _p2pkh,
          },
        ],
      ),
      {_owner, _masternode},
    );
    // A block pays the budget or a masternode, never both.
    expect(tx.pivxKind, PivxTxKind.coldStakeReward);
    expect(tx.pivxAlsoKind, PivxTxKind.budgetPayment);
    expect(tx.pivxAlsoLabel, "Proposal payment");
    expect(
      PivxTxCategory.allOf(tx),
      {PivxTxCategory.coldStakingReward, PivxTxCategory.proposalPayment},
    );
    expect(amount(tx), BigInt.from(504 * _coin));
  });

  test("someone else's stake pays our masternode or our proposal", () {
    Map<String, dynamic> paying(int value) => _coinstake(
      inputAddresses: [_someone],
      inputValue: 1000 * _coin,
      payments: [
        {
          "value": "${1002 * _coin}",
          "addresses": [_someone],
          "hex": _p2pkh,
        },
        {
          "value": "$value",
          "addresses": [_masternode],
          "hex": _p2pkh,
        },
      ],
    );

    final reward = parse(paying(6 * _coin), {_masternode});
    expect(reward.pivxKind, PivxTxKind.masternodeReward);
    expect(reward.pivxAlsoKind, isNull);
    expect(PivxTxCategory.allOf(reward), {PivxTxCategory.masternodeReward});
    expect(amount(reward), BigInt.from(6 * _coin));

    final budget = parse(paying(500 * _coin), {_masternode});
    expect(budget.pivxKind, PivxTxKind.budgetPayment);
    expect(
      budget.statusLabel(
        currentChainHeight: 7000,
        minConfirms: 1,
        minCoinbaseConfirms: 101,
      ),
      "Proposal payment",
    );
    expect(budget.isCoinbase(), isTrue, reason: "matures like a reward");
    expect(amount(budget), BigInt.from(500 * _coin));
  });
}
