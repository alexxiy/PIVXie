import 'dart:typed_data';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_tx_parser.dart';
import 'package:paymint/wallets/wallet/impl/pivx_wallet.dart';

void main() {
  setUpAll(() async => coinlib.loadCoinlib());

  final test73 = Pivx(CryptoCurrencyNetwork.test).stakingAddressPrefix;

  test("staker addresses decode to their key hash", () {
    // From a regtest node: getnewstakingaddress, then validateaddress
    // (its scriptPubKey is the P2PKH of the same hash).
    const address = "WkSHZ7MZ3NfXr8FxsqkkEsVwhNt4EtFsT7";
    final hash = pivxStakingAddressHash(address, test73)!;
    expect(hash.toHex, "eeb931bf0c9561258b4a087d17b9eab445b292b0");
    expect(pivxStakingAddress(hash, test73), address);

    // Not staker addresses: another network, a regular address, typos.
    expect(pivxStakingAddressHash(address, 63), isNull);
    final regular = coinlib.P2PKHAddress.fromHash(
      hash,
      version: Pivx(CryptoCurrencyNetwork.test).networkParams.p2pkhPrefix,
    ).toString();
    expect(pivxStakingAddressHash(regular, test73), isNull);
    expect(pivxStakingAddressHash("${address}x", test73), isNull);
    expect(pivxStakingAddressHash("", test73), isNull);
  });

  test("P2CS script is built and parsed like PIVX Core's", () {
    final staker = Uint8List.fromList(List.generate(20, (i) => i));
    final owner = Uint8List.fromList(List.generate(20, (i) => 100 + i));
    final script = pivxColdStakeScript(stakerHash: staker, ownerHash: owner);
    expect(script.toHex, "76a97b63d114${staker.toHex}6714${owner.toHex}6888ac");
    expect(pivxIsColdStakeScript(script.toHex), isTrue);
    final parsed = pivxParseColdStakeScript(script)!;
    expect(parsed.staker.toHex, staker.toHex);
    expect(parsed.owner.toHex, owner.toHex);

    // The v6 form (OP_CHECKCOLDSTAKEVERIFY) is a delegation too.
    final v6 = Uint8List.fromList(script)..[4] = 0xd2;
    expect(pivxParseColdStakeScript(v6), isNotNull);

    // A P2PKH script is not.
    final p2pkh = "76a914${owner.toHex}88ac".toUint8ListFromHex;
    expect(pivxParseColdStakeScript(p2pkh), isNull);
  });

  test("the owner spends with <sig> OP_FALSE <pubkey>", () {
    final key = coinlib.ECPrivateKey.generate();
    final script = pivxColdStakeScript(
      stakerHash: Uint8List(20),
      ownerHash: coinlib.hash160(key.pubkey.data),
    );
    var tx = coinlib.Transaction(
      version: 1,
      inputs: [
        PivxColdStakeInput(
          prevOut: coinlib.OutPoint(Uint8List(32), 0),
          publicKey: key.pubkey,
          prevScript: script,
        ),
      ],
      outputs: [
        coinlib.Output.fromScriptBytes(BigInt.from(1000), Uint8List(1)),
      ],
    );
    expect(tx.inputs.first.complete, isFalse);
    tx = tx.signLegacy(inputN: 0, key: key);
    final input = tx.inputs.first as PivxColdStakeInput;
    expect(input.complete, isTrue);
    final sig = input.scriptSig;
    final sigLength = sig[0];
    expect(sig[1 + sigLength], 0x00, reason: "OP_FALSE: the owner branch");
    expect(sig[2 + sigLength], 33);
    expect(sig.sublist(3 + sigLength).toHex, key.pubkey.data.toHex);
    expect(input.scriptSig.length + 41, lessThanOrEqualTo(input.signedSize!));

    // Someone else's key is refused.
    expect(
      () => tx.signLegacy(inputN: 0, key: coinlib.ECPrivateKey.generate()),
      throwsException,
    );
  });
}
