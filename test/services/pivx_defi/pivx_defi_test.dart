import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/services/pivx_defi/pivx_defi_api.dart';
import 'package:paymint/services/pivx_defi/pivx_defi_models.dart';
import 'package:paymint/services/pivx_name/pivx_name_resolver.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

const _coin = kPivxDefiCoin;
const _token = "0x804850D326471123b0736e5818e91b87D49A877C";
const _evm = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
const _id = "abcd2345efgh";
const _bridge = "ps1bridgepaymentwallet";

Map<String, dynamic> _infoJson({
  int feeBps = 100,
  String token = _token,
  int chainId = 56,
  String network = "mainnet",
  int wrapMax = 1000 * _coin,
}) => {
  "available": true,
  "paused": false,
  "fee_bps": feeBps,
  "support_url": "mailto:support@example.com",
  "pivx": {
    "network": network,
    "explorer_tx_url": "https://explorer.example/tx/{tx_id}",
    "bridge_addresses": [_bridge, "ps1bridgevault"],
    "names": {"tld": "pivx"},
  },
  "evm": {
    "chain_id": chainId,
    "chain_name": "BNB Smart Chain",
    "explorer_url": "https://bscscan.com/",
  },
  "token": {"address": token, "symbol": "wPIVX", "decimals": 8},
  "wrap": {
    "min": 5 * _coin,
    "min_fee": _coin ~/ 2,
    "max": wrapMax,
    "available": 400 * _coin,
    "confirmations": 40,
  },
  "unwrap": {"min": 5 * _coin, "min_fee": _coin ~/ 2},
};

Map<String, dynamic> _wrapOrder({
  int amount = 10 * _coin,
  String evm = _evm,
  String? memo,
  int? paymentAmount,
  String status = "awaiting_payment",
}) => {
  "id": _id,
  "direction": "wrap",
  "created": 1762800000,
  "amount": "$amount",
  "fee": "${_coin ~/ 2}",
  "receive": "${amount - _coin ~/ 2}",
  "status": status,
  "confirmations_required": 40,
  "evm_address": evm,
  "expires": 1762803600,
  "deposits": <Object>[],
  "payment": {
    "address": _bridge,
    "amount": "${paymentAmount ?? amount}",
    "memo": memo ?? "$_id:${evmChecksumAddress(evm)}",
  },
};

Map<String, dynamic> _unwrapOrder({String pivx = "ps1payout"}) => {
  "id": _id,
  "direction": "unwrap",
  "created": 1762800000,
  "amount": 10 * _coin,
  "fee": _coin ~/ 2,
  "receive": 10 * _coin - _coin ~/ 2,
  "status": "awaiting_tx",
  "confirmations_required": 10,
  "pivx_address": pivx,
  "deposit_address": "0x1111111111111111111111111111111111111111",
};

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();

void main() {
  group("config", () {
    test("mainnet PIVX only, and builds include the bridge by default", () {
      expect(PivxDefiConfig.enabled, isTrue);
      expect(
        PivxDefiConfig.forCoin(Pivx(CryptoCurrencyNetwork.main)),
        same(PivxDefiConfig.mainnet),
      );
      expect(PivxDefiConfig.forCoin(Pivx(CryptoCurrencyNetwork.test)), isNull);
    });
  });

  group("amounts", () {
    test("parse", () {
      expect(parsePivxDefiAmount("1"), _coin);
      expect(parsePivxDefiAmount("12.5"), 1250000000);
      expect(parsePivxDefiAmount("0.00000001"), 1);
      expect(parsePivxDefiAmount(" 3. "), 3 * _coin);
      expect(parsePivxDefiAmount("0.000000001"), isNull);
      expect(parsePivxDefiAmount("1,5"), isNull);
      expect(parsePivxDefiAmount("-1"), isNull);
      expect(parsePivxDefiAmount("1234567890"), isNull);
      expect(parsePivxDefiAmount(""), isNull);
    });

    test("sanitize", () {
      expect(sanitizePivxDefiAmount("1,5"), "1.5");
      expect(sanitizePivxDefiAmount("007"), "7");
      expect(sanitizePivxDefiAmount(".5"), "0.5");
      expect(sanitizePivxDefiAmount("1.2.3"), "1.23");
      expect(sanitizePivxDefiAmount("1.123456789"), "1.12345678");
      expect(sanitizePivxDefiAmount("12a3"), "123");
      expect(sanitizePivxDefiAmount("1234567890"), "123456789");
    });

    test("format and show", () {
      expect(formatPivxDefiAmount(1250000000), "12.5");
      expect(formatPivxDefiAmount(_coin), "1");
      expect(formatPivxDefiAmount(1), "0.00000001");
      expect(formatPivxDefiAmount(0), "0");
      expect(formatPivxDefiAmount(-_coin ~/ 2), "-0.5");
      expect(
        showPivxDefiAmount(123456789 * _coin + _coin ~/ 4),
        "123,456,789.25",
      );
      for (final sat in [0, 1, 99, _coin, 1234567891234]) {
        expect(parsePivxDefiAmount(formatPivxDefiAmount(sat)), sat);
      }
    });
  });

  group("fees", () {
    final info = PivxDefiInfo.fromJson(_infoJson());
    const wrap = PivxDefiDirection.wrap;

    test("percentage, at least the minimum, never above the amount", () {
      expect(info.feeOf(10 * _coin, wrap), _coin ~/ 2);
      expect(info.feeOf(100 * _coin, wrap), _coin);
      // 1% rounded up
      expect(info.feeOf(100 * _coin + 1, wrap), _coin + 1);
      expect(info.feeOf(_coin ~/ 4, wrap), _coin ~/ 4);
    });

    test("sendFor gives the smallest amount that receives the target", () {
      for (final receive in [
        1,
        _coin,
        5 * _coin,
        49 * _coin + 12345,
        50 * _coin,
        123 * _coin + 99999999,
        999 * _coin,
      ]) {
        final send = info.sendFor(receive, wrap);
        expect(send - info.feeOf(send, wrap), greaterThanOrEqualTo(receive));
        expect(
          (send - 1) - info.feeOf(send - 1, wrap),
          lessThan(receive),
          reason: "receive $receive",
        );
      }
      expect(info.sendFor(0, wrap), 0);
    });

    test("wrap maximum mints at most the limit, in whole cents", () {
      final max = info.wrapMaxSend;
      expect(max % 1000000, 0);
      expect(max - info.feeOf(max, wrap), lessThanOrEqualTo(info.wrapMax));
      final next = max + 1000000;
      expect(next - info.feeOf(next, wrap), greaterThan(info.wrapMax));
    });

    test("time and links", () {
      expect(info.wrapMinutes, 42);
      expect(info.supportUri?.scheme, "mailto");
      final txid = "ab" * 32;
      expect(
        info.pivxTxUrl(txid).toString(),
        "https://explorer.example/tx/$txid",
      );
      expect(info.pivxTxUrl("not a txid"), isNull);
      expect(
        info.evmAddressUrl(_evm).toString(),
        "https://bscscan.com/address/$_evm",
      );
      expect(info.evmTxUrl("0x${"cd" * 32}")?.path, "/tx/0x${"cd" * 32}");
      expect(info.evmTxUrl("0x12"), isNull);
      expect(info.names, isTrue);
    });
  });

  group("EVM addresses", () {
    test("keccak-256", () {
      expect(
        _hex(keccak256(const [])),
        "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      );
      expect(
        _hex(keccak256(ascii.encode("depositAddress(string)"))).substring(0, 8),
        kPivxDefiDepositAddressSelector,
      );
    });

    test("EIP-55", () {
      const vectors = [
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
        "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
        "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
        _token,
      ];
      for (final v in vectors) {
        expect(evmChecksumAddress(v.toLowerCase()), v);
        expect(isValidEvmAddress(v), isTrue);
        expect(isValidEvmAddress(v.toLowerCase()), isTrue);
      }
      // one capital wrong
      expect(
        isValidEvmAddress("0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"),
        isFalse,
      );
      expect(isValidEvmAddress("0x${"0" * 40}"), isFalse);
      expect(isValidEvmAddress("0x123"), isFalse);
      expect(evmChecksumAddress("nope"), isNull);
    });

    test("from text", () {
      expect(evmAddressFromText(_evm), _evm);
      expect(evmAddressFromText("ethereum:$_evm@56"), _evm);
      expect(evmAddressFromText("ethereum:$_evm?value=1"), _evm);
      expect(evmAddressFromText("ethereum:pay-$_evm"), isNull);
      expect(evmAddressFromText("${_evm}00"), isNull);
      expect(shortEvmAddress(_evm), "0x5aAe…eAed");
    });

    test("depositAddress call and answer", () {
      const pivx = "ps1abc";
      final call = pivxDefiDepositAddressCall(pivx);
      expect(call.startsWith("0x$kPivxDefiDepositAddressSelector"), isTrue);
      final words = call.substring(10);
      expect(words.length, 3 * 64);
      expect(int.parse(words.substring(0, 64), radix: 16), 0x20);
      expect(int.parse(words.substring(64, 128), radix: 16), pivx.length);
      expect(words.substring(128, 128 + 12), _hex(utf8.encode(pivx)));
      expect(RegExp(r"^0+$").hasMatch(words.substring(128 + 12)), isTrue);

      // 32 bytes exactly: one word, no padding word
      expect(pivxDefiDepositAddressCall("a" * 32).length, 10 + 3 * 64);

      expect(
        decodeEvmAddressWord("0x${"0" * 24}${_evm.substring(2)}"),
        _evm.toLowerCase(),
      );
      expect(decodeEvmAddressWord("0x${"1" * 64}"), isNull);
    });
  });

  group("orders", () {
    test("parse", () {
      final o = PivxDefiOrder.fromJson(_wrapOrder());
      expect(o.isWrap, isTrue);
      expect(o.amount, 10 * _coin);
      expect(o.payment?.address, _bridge);
      expect(o.wrapConfirmations, 0);
      expect(
        () => PivxDefiOrder.fromJson({..._wrapOrder(), "id": "short"}),
        throwsA(isA<PivxDefiFormatException>()),
      );
      expect(isPivxDefiOrderId(_id), isTrue);
      expect(isPivxDefiOrderId("abcd2345efgi"), isFalse); // no i
    });

    test("a wrap matches only what was asked", () {
      const swap = PivxDefiSwap(
        direction: PivxDefiDirection.wrap,
        amount: 10 * _coin,
        evmAddress: _evm,
      );
      expect(
        pivxDefiOrderMatches(PivxDefiOrder.fromJson(_wrapOrder()), swap),
        isTrue,
      );
      // the server lowercased the address: still the same account
      expect(
        pivxDefiOrderMatches(
          PivxDefiOrder.fromJson(_wrapOrder(evm: _evm.toLowerCase())),
          swap,
        ),
        isTrue,
      );
      for (final bad in [
        _wrapOrder(amount: 11 * _coin),
        _wrapOrder(paymentAmount: 9 * _coin),
        _wrapOrder(evm: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"),
        _wrapOrder(memo: "$_id:${_evm.toLowerCase()}"),
        _wrapOrder(memo: "otherorder12:$_evm"),
      ]) {
        expect(
          pivxDefiOrderMatches(PivxDefiOrder.fromJson(bad), swap),
          isFalse,
        );
      }
    });

    test("an unwrap matches its payout address", () {
      const swap = PivxDefiSwap(
        direction: PivxDefiDirection.unwrap,
        amount: 10 * _coin,
        pivxAddress: "ps1payout",
      );
      expect(
        pivxDefiOrderMatches(PivxDefiOrder.fromJson(_unwrapOrder()), swap),
        isTrue,
      );
      expect(
        pivxDefiOrderMatches(
          PivxDefiOrder.fromJson(_unwrapOrder(pivx: "ps1other")),
          swap,
        ),
        isFalse,
      );
    });

    test("poll delays", () {
      PivxDefiOrder order(String status, {Map<String, dynamic>? burn}) =>
          PivxDefiOrder.fromJson({
            ..._unwrapOrder(),
            "status": status,
            "burn": ?burn,
          });
      final unpaid = PivxDefiOrder.fromJson(_wrapOrder());
      expect(
        pivxDefiPollDelay(unpaid, paid: false),
        const Duration(seconds: 10),
      );
      expect(pivxDefiPollDelay(unpaid, paid: true), const Duration(seconds: 4));
      expect(
        pivxDefiPollDelay(order("burning"), paid: false),
        const Duration(seconds: 4),
      );
      expect(
        pivxDefiPollDelay(order("closed"), paid: false),
        const Duration(seconds: 30),
      );
      expect(
        pivxDefiPollDelay(
          order("completed", burn: {"payout_final": false}),
          paid: false,
        ),
        const Duration(seconds: 60),
      );
      expect(
        pivxDefiPollDelay(
          order("completed", burn: {"payout_final": true}),
          paid: false,
        ),
        isNull,
      );
      expect(
        pivxDefiPollDelay(
          PivxDefiOrder.fromJson(_wrapOrder(status: "completed")),
          paid: true,
        ),
        isNull,
      );
    });
  });

  group("API", () {
    PivxDefiApi api(
      PivxNameResponse Function(String method, Uri url, String? body) answer,
    ) => PivxDefiApi(
      PivxDefiConfig.mainnet,
      transport: (method, url, {body}) async => answer(method, url, body),
    );
    PivxNameResponse ok(Object response) =>
        (status: 200, body: jsonEncode({"response": response}));

    test("info is checked against the app's settings", () async {
      final good = await api((_, url, _) {
        expect(url.path, "/api/v1.0/info");
        return ok(_infoJson());
      }).info();
      expect(good.feeBps, 100);
      for (final bad in [
        _infoJson(token: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"),
        _infoJson(chainId: 97),
        _infoJson(network: "testnet"),
      ]) {
        await expectLater(
          api((_, _, _) => ok(bad)).info(),
          throwsA(isA<PivxDefiConfigMismatch>()),
        );
      }
    });

    test("createOrder sends what was asked", () async {
      Map<String, dynamic>? sent;
      final order =
          await api((method, url, body) {
            expect(method, "POST");
            expect(url.path, "/api/v1.0/createOrder");
            sent = jsonDecode(body!) as Map<String, dynamic>;
            return ok(_unwrapOrder());
          }).createOrder(
            const PivxDefiSwap(
              direction: PivxDefiDirection.unwrap,
              amount: 1050000000,
              pivxAddress: "ps1payout",
              pivxName: "alice.pivx",
            ),
          );
      expect(order.pivxAddress, "ps1payout");
      expect(sent, {
        "direction": "unwrap",
        "amount": "10.5",
        "pivx_address": "ps1payout",
        "pivx_name": "alice.pivx",
      });
    });

    test("errors", () async {
      final e = await api(
        (_, _, _) => (
          status: 400,
          body: jsonEncode({
            "error": {"error_message": "Amount is below the minimum"},
          }),
        ),
      ).order(_id).then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<PivxDefiApiException>());
      e as PivxDefiApiException;
      expect(e.message, "Amount is below the minimum");
      expect(e.status, 400);

      final proxy = await api((_, _, _) => (status: 502, body: "<html>"))
          .order(_id)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((proxy! as PivxDefiApiException).status, 502);

      final down = await api((_, _, _) => throw Exception("no route"))
          .reserves()
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((down! as PivxDefiApiException).isNetwork, isTrue);

      // a malformed id never leaves the app
      await expectLater(
        api((_, _, _) => throw StateError("asked")).order("../info"),
        throwsA(
          isA<PivxDefiApiException>().having((e) => e.status, "status", 404),
        ),
      );
    });
  });

  group("deposit address on chain", () {
    final rpcs = [
      Uri.parse("https://rpc-a.example"),
      Uri.parse("https://rpc-b.example"),
      Uri.parse("https://rpc-c.example"),
    ];
    final config = PivxDefiConfig(
      site: PivxDefiConfig.mainnet.site,
      api: PivxDefiConfig.mainnet.api,
      pivxNetwork: "mainnet",
      chainId: 56,
      token: _token.toLowerCase(),
      rpcs: rpcs,
    );
    String word(String address) => "0x${"0" * 24}${address.substring(2)}";

    PivxDefiChain chain(Map<String, Object?> answers) => PivxDefiChain(
      config,
      transport: (method, url, {body}) async {
        final request = jsonDecode(body!) as Map<String, dynamic>;
        if (request["method"] == "eth_blockNumber") {
          return (
            status: 200,
            body: jsonEncode({"jsonrpc": "2.0", "id": 1, "result": "0x100"}),
          );
        }
        final params = request["params"] as List;
        expect((params[0] as Map)["to"], _token.toLowerCase());
        expect(params[1], "0x100");
        final answer = answers[url.host];
        if (answer == null) throw Exception("down");
        return (
          status: 200,
          body: jsonEncode({"jsonrpc": "2.0", "id": 1, "result": answer}),
        );
      },
    );

    test("believed when enough endpoints agree", () async {
      final address = await chain({
        "rpc-a.example": word(_evm),
        "rpc-b.example": word(_evm),
        "rpc-c.example": word(_evm),
      }).depositAddress("ps1payout");
      expect(address, _evm.toLowerCase());
    });

    test("one endpoint down: the next one is asked", () async {
      final address = await chain({
        "rpc-a.example": null,
        "rpc-b.example": word(_evm),
        "rpc-c.example": word(_evm),
      }).depositAddress("ps1payout");
      expect(address, _evm.toLowerCase());
    });

    test("endpoints that disagree stop it", () async {
      await expectLater(
        chain({
          "rpc-a.example": word(_evm),
          "rpc-b.example": word("0x${"2" * 40}"),
          "rpc-c.example": word(_evm),
        }).depositAddress("ps1payout"),
        throwsA(
          isA<PivxDefiChainException>().having(
            (e) => e.kind,
            "kind",
            PivxDefiChainError.disagreement,
          ),
        ),
      );
    });

    test("too few answers: unavailable", () async {
      await expectLater(
        chain({
          "rpc-a.example": null,
          "rpc-b.example": null,
          "rpc-c.example": word(_evm),
        }).depositAddress("ps1payout"),
        throwsA(
          isA<PivxDefiChainException>().having(
            (e) => e.kind,
            "kind",
            PivxDefiChainError.unavailable,
          ),
        ),
      );
    });
  });

  group("reserves", () {
    test("parse", () {
      final r = PivxDefiReserves.fromJson({
        "status": "in_process",
        "supply": "100000000000",
        "balance": "100050000000",
        "difference": "50000000",
        "moving_to_vault": "50000000",
        "token": _token,
        "vault_wallet": "ps1bridgevault",
        "viewing_key": "pxviews1abc",
        "start_block": 5000000,
        "updated": 1762800000,
      });
      expect(r.status, "in_process");
      expect(r.amounts["moving_to_vault"], 50000000);
      expect(r.amounts["surplus"], 0);
      expect(r.startBlock, 5000000);
    });
  });
}
