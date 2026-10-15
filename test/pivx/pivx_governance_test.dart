import 'dart:typed_data';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/pivx_wallet.dart';

void main() {
  setUpAll(() async => coinlib.loadCoinlib());

  test("proposal hash matches PIVX Core's", () {
    // Submitted on regtest; Core's getbudgetinfo gave this Hash and
    // BlockEnd.
    final params = Pivx(CryptoCurrencyNetwork.test).networkParams;
    final payee = coinlib.Address.fromString(
      "yEmYNvwwNPqwcxEcj6uFf2dvdoKAyXsWLz",
      params,
    ).program.script.compiled;
    final end = pivxProposalBlockEnd(
      blockStart: 3744,
      payments: 2,
      cycleBlocks: kPivxBudgetCycleTest,
    );
    expect(end, 4034);
    expect(
      pivxProposalHash(
        name: "PIVXie-test-1",
        url: "https://pivxie.me",
        blockStart: 3744,
        blockEnd: end,
        amountSats: BigInt.from(10 * 100000000),
        payeeScript: payee,
      ),
      "f5078adcbd3ea83f989c0367d5e82e525963193dd7f76a789492be67f7518259",
    );
  });

  test("fee script is OP_RETURN with the hash in internal byte order", () {
    const hash =
        "f5078adcbd3ea83f989c0367d5e82e525963193dd7f76a789492be67f7518259";
    final script = pivxProposalFeeScript(hash);
    expect(script.length, 34);
    expect(script.sublist(0, 2), [0x6a, 0x20]);
    expect(
      script.sublist(2).toHex,
      Uint8List.fromList(hash.toUint8ListFromHex.reversed.toList()).toHex,
    );
  });

  test("pivx.org past proposals are parsed", () {
    // A row as pivx.org/proposals/past renders it (icons left out).
    const html = '''
<table><thead><tr><th>Status</th><th>Name</th><th>Payment</th><th>Votes</th></tr></thead><tbody>
<tr data-hash="775a07b0eaf4b46facdc29004e9f45b93819cd84a52e10266e527242aefb40d1" data-title="Core-Dev-Dec2021"> <td data-order="0.32934131736527"><span class="pass-fund t-upper"><b>Passing</b></span></td> <td><a href="https://bit.ly/3oBvgrR" class="pink-link" target="_blank" rel="noopener"><b>Core-Dev-Dec2021</b><span class="link-icon link-icon-suffix external"><svg/></span></a></td> <td data-order="18000"><b>54,000 <span class="piv-append t-purple1 t-t-almost">PIV</span></b><span class="note-line t-t-almost t-gray"><b><span class="curr-prefix t-purple1 t-t-almost">US&#36;</span>934.52</b></span></td> <td data-order="1">100<span class="t-lightgray">%</span><span class="note-line t-t-small t-gray">990 / 0</span></td> </tr>
<tr data-hash="02a1b2151e5205f63158a72cfb99975cdbe1a1fc765cc4c4e0ff05251221ea46" data-title="Ads &amp; More"> <td data-order="0.01"><span class="t-upper"><b>Failing</b></span></td> <td><a href="https://forum.pivx.org/t/x" class="pink-link"><b>Ads &amp; More</b></a></td> <td data-order="1500.5"><b>3,001 <span class="piv-append">PIV</span></b></td> <td data-order="0.4">40<span>%</span><span class="note-line">20 / 30</span></td> </tr>
</tbody></table>''';
    final past = parsePivxProposalArchive(html, fractionDigits: 8);
    expect(past.length, 2);
    expect(past[0].name, "Core-Dev-Dec2021");
    expect(past[0].passed, isTrue);
    expect(past[0].url, "https://bit.ly/3oBvgrR");
    expect(past[0].monthlyPayment.decimal.toString(), "18000");
    expect(past[0].totalPayment.decimal.toString(), "54000");
    expect((past[0].yeas, past[0].nays), (990, 0));
    expect(past[1].name, "Ads & More");
    expect(past[1].passed, isFalse);
    expect(past[1].monthlyPayment.decimal.toString(), "1500.5");
    expect((past[1].yeas, past[1].nays), (20, 30));
    expect(past[1].yesPercent, 40);
  });

  test("archive text is unescaped once", () {
    final html =
        '<tr data-hash="${"ab" * 32}" data-title="a &amp;lt;3 b">'
        '<td><b>Passing</b></td><td><a href="https://x.org/?a=1&amp;b=2">'
        '</a></td><td data-order="1"><b>1 <span>PIV</span></b></td>'
        '<td data-order="1">1 / 0</td></tr>';
    final past = parsePivxProposalArchive(html, fractionDigits: 8);
    expect(past.single.name, "a &lt;3 b");
    expect(past.single.url, "https://x.org/?a=1&b=2");
  });

  test("a proposal payout is found in the superblock's coinstake", () {
    // Regtest superblock 8064 paid the 10 PIV proposal "budgettest3".
    const payee = "yDTMsQVS3ZAfweCPbtLXDHKuJZyejNyBVw";
    final txs = [
      {
        "txid": "50767c9b60ed03de",
        "blockHeight": 8064,
        "coinstake": true,
        "coinbase": false,
        "vout": [
          {"value": "0", "addresses": <String>[]},
          {
            "value": "2400000000",
            "addresses": ["yECK47R6X9gXe6HoZ2k14G1gyxUtLRCe9p"],
          },
          {
            "value": "1000000000",
            "addresses": [payee],
          },
        ],
      },
    ];
    final paid = pivxPaidPayout(
      txs,
      address: payee,
      superblock: 8064,
      fractionDigits: 8,
    )!;
    expect(paid.state, PivxPayoutState.paid);
    expect(paid.txid, "50767c9b60ed03de");
    expect(paid.height, 8064);
    expect(paid.amount!.raw, BigInt.from(1000000000));

    // A plain payment to the address is not a payout, nor is one before
    // the superblock.
    final plain = {...txs.first, "coinstake": false};
    expect(
      pivxPaidPayout(
        [plain],
        address: payee,
        superblock: 8064,
        fractionDigits: 8,
      ),
      isNull,
    );
    expect(
      pivxPaidPayout(txs, address: payee, superblock: 8208, fractionDigits: 8),
      isNull,
    );
  });
}
