import 'dart:convert';

import 'package:cryptography/cryptography.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/services/pivx_name/pivx_name.dart';
import 'package:paymint/services/pivx_name/pivx_name_resolver.dart';
import 'package:paymint/services/pivx_name/pivx_names_identity.dart';
import 'package:paymint/services/pivx_name/pivx_names_protocol.dart';
import 'package:paymint/services/pivx_name/pivx_names_registrar.dart';

import 'pivx_name_fixtures.dart';

List<int> _bytes(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();

const _abandon =
    "abandon abandon abandon abandon abandon abandon abandon abandon "
    "abandon abandon abandon about";

/// Public keys the PIVX.name web app (pivx-name-front, its vendored
/// noble-ed25519) makes from these phrases.
const _webKeys = {
  _abandon: "93a5f261984931e0df5c7434b16d468efb1953098d3cad4fa1506b9e052e7fc7",
  "legal winner thank year wave sausage worth useful legal winner thank "
          "yellow":
      "eeb26d6330e1a1ab634e8b3609a17751741ce2fb49502d2f61b2e85cb3b00152",
  "abandon abandon abandon abandon abandon abandon abandon abandon "
          "abandon abandon abandon abandon abandon abandon abandon abandon "
          "abandon abandon abandon abandon abandon abandon abandon art":
      "fa65ae17f70f9c861df38ffca5c7b30dbf731459a86869faeb7e300be8bd1a38",
};

void main() {
  group("identity", () {
    test("the same key as the web app makes from the phrase", () async {
      for (final e in _webKeys.entries) {
        final identity = await PivxNamesIdentity.fromMnemonic(e.key);
        expect(identity.publicKey, e.value, reason: e.key);
      }
    });

    test("case and spacing of the phrase don't matter", () async {
      final identity = await PivxNamesIdentity.fromMnemonic(
        "  Abandon abandon\tabandon abandon abandon abandon abandon  abandon "
        "abandon abandon abandon ABOUT\n",
      );
      expect(identity.publicKey, _webKeys[_abandon]);
    });

    test("signatures verify, with a fresh nonce per message", () async {
      final identity = await PivxNamesIdentity.fromMnemonic(_abandon);
      final key = c.SimplePublicKey(
        _bytes(identity.publicKey),
        type: c.KeyPairType.ed25519,
      );
      final messages = [
        "PiNS:1:REG:alice.pivx:$liveTarget:${identity.publicKey}:1760000000",
        "in:${identity.publicKey}:1:10",
        "ünïcode ✓",
      ];
      final rs = <String>{};
      for (final m in messages) {
        final sig = await identity.sign(m);
        expect(sig, matches(RegExp(r"^[0-9a-f]{128}$")));
        expect(
          await c.Ed25519().verify(
            utf8.encode(m),
            signature: c.Signature(_bytes(sig), publicKey: key),
          ),
          isTrue,
          reason: m,
        );
        rs.add(sig.substring(0, 64));
      }
      // The web app's signatures share one R for all messages of a key,
      // which gives the key away; these must not.
      expect(rs, hasLength(messages.length));
    });

    test("Ed25519 is RFC 8032's", () async {
      // RFC 8032, 7.1, tests 1 and 2.
      final vectors = [
        (
          seed: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
          pub: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
          msg: "",
          sig:
              "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
              "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
        ),
        (
          seed: "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
          pub: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
          msg: "72",
          sig:
              "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
              "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
        ),
      ];
      final ed = c.Ed25519();
      for (final v in vectors) {
        final pair = await ed.newKeyPairFromSeed(_bytes(v.seed));
        expect(_hex((await pair.extractPublicKey()).bytes), v.pub);
        final sig = await ed.sign(_bytes(v.msg), keyPair: pair);
        expect(_hex(sig.bytes), v.sig);
      }
    });
  });

  group("commands", () {
    const key =
        "93a5f261984931e0df5c7434b16d468efb1953098d3cad4fa1506b9e052e7fc7";
    const other =
        "eeb26d6330e1a1ab634e8b3609a17751741ce2fb49502d2f61b2e85cb3b00152";

    test("as the web app spells them", () {
      String cmd(
        PivxNamesOp op, {
        String? target,
        String? newOwner,
        BigInt? price,
      }) => pivxNamesCommand(
        marker: "PiNS",
        op: op,
        name: "alice.pivx",
        nonce: 1760000000,
        pubkey: key,
        target: target,
        newOwner: newOwner,
        priceSats: price,
      );
      for (final op in [PivxNamesOp.reg, PivxNamesOp.upd, PivxNamesOp.buy]) {
        expect(
          cmd(op, target: liveTarget),
          "PiNS:1:${op.code}:alice.pivx:$liveTarget:$key:1760000000",
        );
      }
      expect(
        cmd(PivxNamesOp.chg, newOwner: other),
        "PiNS:1:CHG:alice.pivx:$other:1760000000",
      );
      expect(
        cmd(PivxNamesOp.lst, price: BigInt.from(1250000000)),
        "PiNS:1:LST:alice.pivx:$key:1250000000:1760000000",
      );
      expect(cmd(PivxNamesOp.ult), "PiNS:1:ULT:alice.pivx:$key:1760000000");
    });

    test("withdrawal and history messages", () {
      expect(
        pivxNamesWithdrawMessage(
          marker: "PiNS",
          pubkey: key,
          address: liveTarget,
          amountSats: BigInt.from(95000000),
          nonce: 1760000000,
        ),
        "PiNS:1:WDR:$key:$liveTarget:95000000:1760000000",
      );
      expect(
        pivxNamesHistoryMessage(
          marker: "PiNS",
          type: "ref",
          pubkey: key,
          page: 2,
          count: 10,
          nonce: 1760000000,
        ),
        "PiNS:1:TXS:ref:$key:2:10:1760000000",
      );
    });

    test("memo room", () {
      final longest = "${"a" * 58}.pivx";
      final command = pivxNamesCommand(
        marker: "PiNS",
        op: PivxNamesOp.reg,
        name: longest,
        nonce: 1760000000,
        pubkey: key,
        target: liveTarget,
      );
      expect(pivxNamesCommandFits(command), isTrue);
      expect(pivxNamesCommandFits("x" * (512 - 129)), isTrue);
      expect(pivxNamesCommandFits("x" * (512 - 128)), isFalse);
      final room = pivxNamesMaxTargetLength(
        marker: "PiNS",
        name: longest,
        op: PivxNamesOp.reg,
        nonce: 1760000000,
      );
      expect(room, greaterThanOrEqualTo(liveTarget.length));
      expect(
        command.length + 1 + 128 - liveTarget.length + room,
        kPivxNamesMemoMaxBytes,
      );
    });

    test("op codes", () {
      for (final op in PivxNamesOp.values) {
        expect(PivxNamesOp.fromCode(op.code), op);
      }
      expect(PivxNamesOp.fromCode("WDR"), isNull);
      expect(PivxNamesOp.values.where((e) => e.hasTarget), [
        PivxNamesOp.reg,
        PivxNamesOp.upd,
        PivxNamesOp.buy,
      ]);
    });
  });

  group("prices", () {
    test("parse", () {
      final cases = {
        "1": BigInt.from(100000000),
        "12.5": BigInt.from(1250000000),
        " 0.00000001 ": BigInt.one,
        "50000000": BigInt.from(50000000) * BigInt.from(100000000),
        "0": null,
        "0.0": null,
        "50000000.00000001": null,
        "1.123456789": null,
        "1,5": null,
        "-1": null,
        ".5": null,
        "1.": null,
        "1e3": null,
        "": null,
      };
      for (final e in cases.entries) {
        expect(parsePivxNamesPrice(e.key), e.value, reason: e.key);
      }
    });

    test("parse in a smaller unit", () {
      expect(parsePivxNamesPrice("4500", shift: 3), BigInt.from(450000000));
      expect(parsePivxNamesPrice("0.01", shift: 3), BigInt.from(1000));
      expect(parsePivxNamesPrice("0.00001", shift: 3), BigInt.one);
      expect(parsePivxNamesPrice("0.000001", shift: 3), null);
      expect(parsePivxNamesPrice("1", shift: 8), BigInt.one);
      expect(parsePivxNamesPrice("1.5", shift: 8), null);
      expect(
        parsePivxNamesPrice("50000000000", shift: 3),
        BigInt.from(50000000) * BigInt.from(100000000),
      );
      expect(parsePivxNamesPrice("50000000001", shift: 3), null);
    });

    test("format", () {
      expect(pivxNamesPivx(BigInt.from(100000000)), "1");
      expect(pivxNamesPivx(BigInt.from(1250000000)), "12.5");
      expect(pivxNamesPivx(BigInt.one), "0.00000001");
      expect(pivxNamesPivx(BigInt.zero), "0");
      expect(pivxNamesPivx(BigInt.from(450000000), shift: 3), "4500");
      expect(pivxNamesPivx(BigInt.one, shift: 3), "0.00001");
      expect(pivxNamesPivx(BigInt.from(12), shift: 8), "12");
    });
  });

  group("names", () {
    test("the search field keeps a label", () {
      final cases = {
        "Alice": "alice",
        "--al--ice-": "al-ice-",
        "a.l_i ce!": "alice",
        "ünï": "n",
        "": "",
      };
      for (final e in cases.entries) {
        expect(sanitizePivxNamesLabel(e.key), e.value, reason: e.key);
      }
    });

    test("labels", () {
      for (final ok in ["a", "alice", "a-b", "a1-b2-c3", "123"]) {
        expect(isValidPivxNamesLabel(ok), isTrue, reason: ok);
      }
      for (final bad in ["", "-a", "a-", "a--b", "A", "a.b", "a_b"]) {
        expect(isValidPivxNamesLabel(bad), isFalse, reason: bad);
      }
    });

    test("split", () {
      expect(splitPivxName("alice.pivx"), (label: "alice", zone: ".pivx"));
      expect(splitPivxName("alice"), (label: "alice", zone: ""));
    });
  });

  group("public keys", () {
    test("real keys", () {
      for (final key in [
        ..._webKeys.values,
        liveOwnerKey,
        // The base point.
        "5866666666666666666666666666666666666666666666666666666666666666",
      ]) {
        expect(isValidPivxNamesPublicKey(key), isTrue, reason: key);
      }
    });

    test("refused", () {
      final cases = {
        "uppercase": _webKeys[_abandon]!.toUpperCase(),
        "short": _webKeys[_abandon]!.substring(2),
        "not hex": "zz${_webKeys[_abandon]!.substring(2)}",
        "y not below p":
            "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "not on the curve":
            "0200000000000000000000000000000000000000000000000000000000000000",
        "identity":
            "0100000000000000000000000000000000000000000000000000000000000000",
        "order 2":
            "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "order 4":
            "0000000000000000000000000000000000000000000000000000000000000000",
        "order 4, negated":
            "0000000000000000000000000000000000000000000000000000000000000080",
        "order 8":
            "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
        "order 8, negated":
            "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
        // A real key plus a point of order 8.
        "mixed order":
            "8d5fad5c69c8ac1e200879323df4f33a23c5c91d82645a9d24efcf6865163987",
      };
      for (final e in cases.entries) {
        expect(isValidPivxNamesPublicKey(e.value), isFalse, reason: e.key);
      }
    });
  });

  group("registrar", () {
    late Map<String, Object? Function(Map<String, dynamic>? body)> routes;
    late List<String> calls;

    PivxNamesRegistrar registrar() {
      Future<PivxNameResponse> transport(
        String method,
        Uri url, {
        String? body,
      }) async {
        expect(url.host, "registrar.pivx.name");
        final path = url.path.replaceFirst("/v1.0/", "");
        calls.add("$method $path");
        final json = body == null
            ? null
            : jsonDecode(body) as Map<String, dynamic>;
        final route = routes[path];
        if (route == null) throw Exception("offline");
        final answer = route(json);
        return (
          status: 200,
          body: answer is String ? answer : jsonEncode({"response": answer}),
        );
      }

      return PivxNamesRegistrar(PivxNamesService.mainnet, transport: transport);
    }

    setUp(() {
      routes = {};
      calls = [];
    });

    test("payment address, checked and kept", () async {
      routes["getPaymentAddress"] = (_) => {
        "address": liveTarget,
        "network": "mainnet",
      };
      final r = registrar();
      final info = await r.paymentInfo();
      expect(info.address, liveTarget);
      expect(info.paymentConfirmations, 40);
      expect(info.refundConfirmations, 120);
      expect(info.zones, kPivxNameZones);
      await r.paymentInfo();
      expect(calls, ["GET getPaymentAddress"]);
    });

    test("zones, as served, of those the app knows", () async {
      Object? zones;
      routes["getPaymentAddress"] = (_) => {
        "address": liveTarget,
        "network": "mainnet",
        "zones": zones,
      };
      zones = ["safe", "pivx", "moon", "pivx"];
      expect(await registrar().zones(), ["safe", "pivx"]);
      for (final odd in [
        <String>[],
        ["moon"],
        "pivx",
      ]) {
        zones = odd;
        await expectLater(
          registrar().zones(),
          throwsA(isA<PivxNamesException>()),
          reason: "$odd",
        );
      }
    });

    test("confirmation targets, when served", () async {
      routes["getPaymentAddress"] = (_) => {
        "address": liveTarget,
        "network": "mainnet",
        "payment_confirmations": 10,
        "refund_confirmations": 0,
      };
      final info = await registrar().paymentInfo();
      expect(info.paymentConfirmations, 10);
      expect(info.refundConfirmations, 120);
    });

    test("a wrong payment address is refused, then asked again", () async {
      var network = "testnet";
      routes["getPaymentAddress"] = (_) => {
        "address": liveTarget,
        "network": network,
      };
      final r = registrar();
      await expectLater(r.paymentInfo(), throwsA(isA<PivxNamesException>()));
      network = "mainnet";
      expect((await r.paymentInfo()).address, liveTarget);

      routes["getPaymentAddress"] = (_) => {
        "address": liveTarget.toUpperCase(),
        "network": "mainnet",
      };
      await expectLater(
        registrar().paymentInfo(),
        throwsA(isA<PivxNamesException>()),
      );
    });

    test("availability", () async {
      final answers = {
        "free.pivx": {
          "exists": false,
          "price": 1200000000,
          "reg_pending": false,
          "update_price": 100000000,
        },
        "paid.pivx": {
          "exists": false,
          "price": 1200000000,
          "reg_pending": true,
          "update_price": 100000000,
        },
        "taken.pivx": {"exists": true, "update_price": 300000000},
        "sale.pivx": {
          "exists": true,
          "price": "500000000.00000000",
          "pubkey": liveOwnerKey,
          "update_price": 100000000,
        },
        // Without the update price, or (free) without saying whether
        // someone's registration is on its way.
        "old.pivx": {"exists": true},
        "old2.pivx": {
          "exists": false,
          "price": 1200000000,
          "update_price": 100000000,
        },
      };
      routes.addAll({
        for (final e in answers.entries)
          "check/${e.key}": (body) {
            expect(body, {"with_pubkey": true});
            return e.value;
          },
      });
      final r = registrar();
      final free = await r.check("free.pivx") as PivxNamesAvailable;
      expect(free.price, BigInt.from(1200000000));
      expect(free.pending, isFalse);
      expect(free.updatePrice, BigInt.from(100000000));
      expect((await r.check("paid.pivx") as PivxNamesAvailable).pending, true);
      final taken = await r.check("taken.pivx");
      expect(taken, isA<PivxNamesTaken>());
      expect(taken.updatePrice, BigInt.from(300000000));
      final sale = await r.check("sale.pivx") as PivxNamesListed;
      expect(sale.price, BigInt.from(500000000));
      expect(sale.owner, liveOwnerKey);
      expect(sale.updatePrice, BigInt.from(100000000));
      for (final name in ["old.pivx", "old2.pivx"]) {
        await expectLater(
          r.check(name),
          throwsA(isA<PivxNamesException>()),
          reason: name,
        );
      }
    });

    test("progress, by memo then by transaction", () async {
      const memo = "PiNS:1:REG:alice.pivx:x:y:1:sig";
      var seen = false;
      routes["check/alice.pivx"] = (body) {
        if (body!.containsKey("reg_id")) {
          expect(body["reg_id"], base64.encode(utf8.encode(memo)));
          return seen ? {"tx_id": "ab" * 32} : <String, Object>{};
        }
        expect(body["tx_id"], "ab" * 32);
        return {"status": 0, "confirmations": "12"};
      };
      final r = registrar();
      final none = await r.progressByMemo("alice.pivx", memo);
      expect(none.txId, isNull);
      expect(none.status, isNull);
      seen = true;
      final found = await r.progressByMemo("alice.pivx", memo);
      expect(found.txId, "ab" * 32);
      final status = await r.progressByTxId("alice.pivx", found.txId!);
      expect(status.status, PivxNamesTxStatus.confirmingPayment);
      expect(status.confirmations, 12);
    });

    test("names lists, sorted and filtered by the registrar", () async {
      routes["domains"] = (body) {
        final echo = {
          for (final k in ["sort", "order", "zone", "status"]) k: body![k],
          "min_price": null,
          "max_price": null,
        };
        if (body!["type"] == "my") {
          expect(body, {
            "type": "my",
            "pubkey": liveOwnerKey,
            "page": 2,
            "count": 20,
            "search": "ali",
            "sort": "price",
            "order": "desc",
            "zone": "pivx",
            "status": "listed",
          });
          return {
            ...echo,
            "count": 21,
            "domains": [
              {
                "domain": "alice.pivx",
                "price": 300000000,
                "tx_price": 100000000,
                "address": liveTarget,
                "updated_ts": 1760000000,
              },
              {"domain": "Bad Name", "price": 0, "tx_price": 1},
            ],
          };
        }
        // No key: each name comes with its owner's.
        expect(body.containsKey("pubkey"), isFalse);
        expect(body["count"], 20);
        expect(body["sort"], "listed");
        expect(body["order"], "desc");
        expect(body["zone"], "");
        expect(body["status"], "all");
        final first = body["after"] == null;
        if (!first) expect(body["after"], "WyJsaXN0ZWQiXQ");
        return {
          ...echo,
          "count": 2,
          "domains": [
            {
              "domain": first ? "sale.pivx" : "more.safe",
              "price": 700000000,
              "tx_price": 100000000,
              "pubkey": liveOwnerKey,
              "listed_ts": 1760000000,
            },
          ],
          "next": first ? "WyJsaXN0ZWQiXQ" : null,
        };
      };
      final r = registrar();
      final mine = await r.myNames(
        pubkey: liveOwnerKey,
        page: 2,
        search: "ali",
        filter: (
          status: PivxNamesStatusFilter.onSale,
          zone: "pivx",
          sort: PivxNamesSort.priceDesc,
        ),
      );
      expect(mine.count, 21);
      expect(mine.items, hasLength(1));
      expect(mine.items.single.name, "alice.pivx");
      expect(mine.items.single.price, BigInt.from(300000000));
      expect(mine.items.single.updatePrice, BigInt.from(100000000));
      expect(mine.items.single.address, liveTarget);

      const newest = (
        status: PivxNamesStatusFilter.all,
        zone: null,
        sort: PivxNamesSort.newest,
      );
      final market = await r.marketplace(filter: newest);
      expect(market.count, 2);
      expect(market.items.single.price, BigInt.from(700000000));
      expect(market.items.single.owner, liveOwnerKey);
      expect(market.next, "WyJsaXN0ZWQiXQ");
      final more = await r.marketplace(after: market.next, filter: newest);
      expect(more.items.single.name, "more.safe");
      expect(more.next, isNull);
    });

    test("a list not sorted or filtered as asked is refused", () async {
      Map<String, Object?> answer = {};
      routes["domains"] = (_) => answer;
      final r = registrar();
      // A registrar from before the options: no word about them.
      answer = {
        "count": 1,
        "domains": [
          {"domain": "a.pivx", "price": 1, "tx_price": 1},
        ],
      };
      await expectLater(r.marketplace(), throwsA(isA<PivxNamesException>()));
      // Another order than the one asked for.
      answer = {
        ...answer,
        "sort": "name",
        "order": "asc",
        "zone": "",
        "status": "all",
        "next": null,
      };
      await expectLater(
        r.marketplace(
          filter: (
            status: PivxNamesStatusFilter.all,
            zone: null,
            sort: PivxNamesSort.nameDesc,
          ),
        ),
        throwsA(isA<PivxNamesException>()),
      );
      expect((await r.marketplace()).items.single.name, "a.pivx");
      // No update price, or the marketplace without its place.
      for (final odd in [
        {
          ...answer,
          "domains": [
            {"domain": "a.pivx", "price": 1},
          ],
        },
        {...answer}..remove("next"),
        {...answer, "next": ""},
      ]) {
        answer = odd;
        await expectLater(
          r.marketplace(),
          throwsA(isA<PivxNamesException>()),
          reason: "$odd",
        );
      }
    });

    test("balance and withdrawal", () async {
      routes["balance"] = (body) => switch (body!["action"]) {
        "get" => {"balance": "250000000", "fee": "abc"},
        _ => body["amount"] == "250000000" ? 1 : 0,
      };
      final r = registrar();
      final balance = await r.balance(liveOwnerKey);
      expect(balance.balance, BigInt.from(250000000));
      expect(balance.feePercent, kPivxNamesDefaultRefundFee);
      // An older registrar: no minimum.
      expect(balance.minWithdrawal, BigInt.zero);
      await r.withdraw(
        pubkey: liveOwnerKey,
        address: liveTarget,
        amount: BigInt.from(250000000),
        nonce: 1,
        signature: "00",
      );
      await expectLater(
        r.withdraw(
          pubkey: liveOwnerKey,
          address: liveTarget,
          amount: BigInt.one,
          nonce: 1,
          signature: "00",
        ),
        throwsA(isA<PivxNamesException>()),
      );
    });

    test("minimum withdrawal", () async {
      Object? served;
      routes["balance"] = (_) => {
        "balance": "40000000",
        "fee": 5,
        "min_withdrawal": served,
      };
      final r = registrar();
      Future<BigInt> minimum(Object? value) async {
        served = value;
        return (await r.balance(liveOwnerKey)).minWithdrawal;
      }

      // 0.5 PIVX after the 5% fee, rounded up.
      expect(await minimum(52631579), BigInt.from(52631579));
      expect(await minimum("52631579"), BigInt.from(52631579));
      for (final odd in [null, "abc", -1, "0.5", 1.5, <int>[]]) {
        expect(await minimum(odd), BigInt.zero, reason: "$odd");
      }
    });

    test("history", () async {
      routes["transactions"] = (body) {
        expect(body!["count"], 10);
        expect(body["signature"], "sig");
        expect(body["nonce"], 1760000000);
        return body["type"] == "in"
            ? {
                "count": 1,
                "tx": [
                  {
                    "block_id": 5000000,
                    "time": 1760000000,
                    "domain_name": "alice.pivx",
                    "op": "LST",
                    "amount": 100000000,
                    "price": 2500000000,
                    "confirmations": 3,
                    "status": 2,
                    "tx_id": "cd" * 32,
                    "memo": "PiNS:1:REG:…",
                  },
                ],
              }
            : {
                "count": 1,
                "tx": [
                  {
                    "date": 1760000000,
                    "amount": "95000000",
                    "fee": "5%",
                    "address": liveTarget,
                    "tx_id": "ef" * 32,
                    "status": 3,
                  },
                ],
              };
      };
      final r = registrar();
      final incoming = await r.incoming(
        pubkey: liveOwnerKey,
        page: 1,
        nonce: 1760000000,
        signature: "sig",
      );
      final paid = incoming.items.single;
      expect(paid.status, PivxNamesTxStatus.queuedProof);
      expect(paid.name, "alice.pivx");
      expect(paid.time, DateTime.utc(2025, 10, 9, 8, 53, 20));
      expect(paid.amount, BigInt.from(100000000));
      expect(paid.price, BigInt.from(2500000000));
      final refunds = await r.refunds(
        pubkey: liveOwnerKey,
        page: 1,
        nonce: 1760000000,
        signature: "sig",
      );
      final refund = refunds.items.single;
      expect(refund.date, DateTime.utc(2025, 10, 9, 8, 53, 20));
      expect(refund.amount, BigInt.from(95000000));
      expect(refund.fee, "5");
      expect(refund.address, liveTarget);
      expect(refund.status, PivxNamesRefundStatus.paid);
      // TX_REFUND_* of the registrar's config.php.
      expect(
        [for (var i = 0; i <= 6; i++) PivxNamesRefundStatus.fromCode(i)],
        [
          PivxNamesRefundStatus.waiting,
          PivxNamesRefundStatus.queued,
          PivxNamesRefundStatus.sending,
          PivxNamesRefundStatus.paid,
          PivxNamesRefundStatus.error,
          PivxNamesRefundStatus.solo,
          null,
        ],
      );
      // As the web app: everything still on its way reads as queued.
      for (final s in [
        PivxNamesRefundStatus.queued,
        PivxNamesRefundStatus.sending,
        PivxNamesRefundStatus.solo,
      ]) {
        expect(s.label, "Queued");
      }
    });

    test("errors", () async {
      routes["balance"] = (_) => jsonEncode({
        "error": {"error_message": "Invalid\u202e signature\n"},
      });
      routes["domains"] = (_) => "<html>502</html>";
      final r = registrar();
      await expectLater(
        r.balance(liveOwnerKey),
        throwsA(
          isA<PivxNamesException>()
              .having((e) => e.fromServer, "fromServer", isTrue)
              .having((e) => e.message, "message", "Invalid  signature"),
        ),
      );
      await expectLater(
        r.marketplace(),
        throwsA(
          isA<PivxNamesException>().having(
            (e) => e.fromServer,
            "fromServer",
            isFalse,
          ),
        ),
      );
      await expectLater(r.check("x.pivx"), throwsA(isA<PivxNamesException>()));
    });

    test("history text is cleaned, odd txids dropped", () async {
      routes["transactions"] = (body) => {
        "count": 1,
        "tx": [
          {
            "domain_name": "ali\u202ece.pivx",
            "op": "UPD\n",
            "confirmations": "7",
            "status": "1",
            "tx_id": "AB" * 32,
            "memo": "PiNS:1:UPD:\u2066x",
          },
          {"domain_name": "bob.pivx", "time": null, "tx_id": "zz", "status": 9},
        ],
      };
      final r = registrar();
      final items = (await r.incoming(
        pubkey: liveOwnerKey,
        page: 1,
        nonce: 1760000000,
        signature: "sig",
      )).items;
      expect(items[0].name, "ali ce.pivx");
      expect(items[0].op, "UPD");
      expect(items[0].confirmations, 7);
      expect(items[0].status, PivxNamesTxStatus.pendingProof);
      expect(items[0].txId, "ab" * 32);
      expect(items[0].memo, "PiNS:1:UPD: x");
      expect(items[0].time, isNull);
      expect(items[0].amount, BigInt.zero);
      expect(items[1].time, isNull);
      expect(items[1].txId, "");
      expect(items[1].status, PivxNamesTxStatus.rejected);
      // Not a name: never put in a lookup path.
      await expectLater(
        r.progressByTxId(items[0].name, items[0].txId),
        throwsA(isA<PivxNamesException>()),
      );
      await expectLater(
        r.progressByMemo("../balance", "m"),
        throwsA(isA<PivxNamesException>()),
      );
      expect(calls, ["POST transactions"]);
    });

    test("a clock that is off is named", () async {
      routes["transactions"] = (_) => jsonEncode({
        "error": {"error_message": "Request timeout"},
      });
      routes["balance"] = routes["transactions"]!;
      final r = registrar();
      final clock = isA<PivxNamesException>().having(
        (e) => e.message,
        "message",
        contains("clock"),
      );
      await expectLater(
        r.refunds(
          pubkey: liveOwnerKey,
          page: 1,
          nonce: 1760000000,
          signature: "sig",
        ),
        throwsA(clock),
      );
      await expectLater(
        r.withdraw(
          pubkey: liveOwnerKey,
          address: "ps1",
          amount: BigInt.one,
          nonce: 1760000000,
          signature: "sig",
        ),
        throwsA(clock),
      );
    });

    test("statuses", () {
      expect(PivxNamesTxStatus.fromCode(5), PivxNamesTxStatus.done);
      expect(PivxNamesTxStatus.fromCode(10), isNull);
      expect(PivxNamesTxStatus.values.where((s) => s.isFinal), [
        PivxNamesTxStatus.done,
        PivxNamesTxStatus.orphaned,
        PivxNamesTxStatus.refunded,
        PivxNamesTxStatus.rejected,
      ]);
      expect(PivxNamesTxStatus.done.failed, isFalse);
      expect(PivxNamesTxStatus.pendingRefund.isFinal, isFalse);
    });
  });
}
