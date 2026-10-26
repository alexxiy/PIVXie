import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/services/pivx_name/pivx_name_resolver.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

import 'pivx_name_fixtures.dart';

final _olderRoot = "aa" * 32;
final _newerRoot = "bb" * 32;
final _unknownRoot = "cc" * 32;

/// One BNB Smart Chain endpoint.
class _Rpc {
  _Rpc(this.height);

  /// The newest block it has.
  int height;

  /// Throws instead of answering (connection refused, timeout, ...).
  Object? down;

  /// Answers with this HTTP status and no JSON.
  int? httpStatus;

  /// Answers with a JSON-RPC error object.
  bool rpcError = false;

  /// Answers "0x".
  bool empty = false;

  /// Answers well formed but different: this root instead of the real one.
  String? lieRoot;
}

/// The anchor contract, a few endpoints and a PIVX.name server.
class _Net {
  _Net({List<int>? heights}) {
    for (final (i, h) in (heights ?? [100, 100, 100, 100, 100]).indexed) {
      rpcs[Uri.parse("https://rpc$i.test")] = _Rpc(h);
    }
  }

  final rpcs = <Uri, _Rpc>{};

  /// The contract's current root at each block: blocks from the key on.
  final roots = <int, String>{0: liveRoot};

  /// Roots the contract accepted, and from which block.
  final validFrom = <String, int>{liveRoot: 0, _olderRoot: 0};
  int epoch = 1;

  /// Called when the contract is asked about a root it doesn't know at that
  /// block (time passes in a recheck).
  void Function()? onUnknownRoot;

  String serverRoot = liveRoot;
  final records = <String, Map<String, dynamic>>{"alexxiy.pivx": liveRecord()};

  /// A server that answers with this error text.
  String? serverError;
  String? serverBody;
  var serverDown = false;

  final log = <String>[];

  late final service = PivxNameService(
    indexer: Uri.parse("https://indexer.test"),
    anchor: "0xanchor",
    rpcs: rpcs.keys.toList(),
    epochs: const {1},
  );

  PivxNameResolver resolver() => PivxNameResolver(
    service,
    transport: transport,
    recheckDelay: Duration.zero,
  );

  String rootAt(int block) =>
      roots.entries.where((e) => e.key <= block).reduce((a, b) {
        return a.key > b.key ? a : b;
      }).value;

  Future<PivxNameResponse> transport(
    String method,
    Uri url, {
    String? body,
  }) async {
    if (url.host == "indexer.test") return _server(method, url);
    final rpc = rpcs[url]!;
    final request = jsonDecode(body!) as Map<String, dynamic>;
    final params = request["params"] as List;
    log.add(
      "${url.host} ${request["method"]}"
      "${params.isEmpty ? "" : " ${(params[0] as Map)["data"].toString().substring(0, 10)} @${params[1]}"}",
    );
    if (rpc.down != null) throw rpc.down!;
    if (rpc.httpStatus != null) {
      return (status: rpc.httpStatus!, body: "<html>");
    }
    if (rpc.rpcError) {
      return _json({
        "jsonrpc": "2.0",
        "id": 1,
        "error": {"message": "limit"},
      });
    }
    if (rpc.empty) return _json({"jsonrpc": "2.0", "id": 1, "result": "0x"});
    if (request["method"] == "eth_blockNumber") {
      return _result("0x${rpc.height.toRadixString(16)}");
    }
    final block = int.parse((params[1] as String).substring(2), radix: 16);
    if (block > rpc.height) {
      return _json({
        "jsonrpc": "2.0",
        "id": 1,
        "error": {"message": "header not found"},
      });
    }
    final data = (params[0] as Map)["data"] as String;
    if (data == "0x8d39310a") {
      final root = rpc.lieRoot ?? rootAt(block);
      return _result("0x$root${_word(5541718)}${_word(epoch)}");
    }
    if (data.startsWith("0x30ef41b4")) {
      final root = data.substring(10);
      final from = validFrom[root];
      final known = from != null && from <= block;
      if (!known) onUnknownRoot?.call();
      return _result("0x${_word(known ? 1 : 0)}");
    }
    throw StateError("unexpected call $data");
  }

  PivxNameResponse _server(String method, Uri url) {
    log.add("server ${url.path}");
    if (serverDown) throw TimeoutException("No answer");
    if (serverBody != null) return (status: 200, body: serverBody!);
    // The error answers lookups; the root is still served.
    if (serverError != null && url.path != "/v1.0/getRoot") {
      return _json({
        "error": {"error_message": serverError},
      });
    }
    if (url.path == "/v1.0/getRoot") return _json({"response": serverRoot});
    final name = url.pathSegments.last;
    final record = records[name];
    if (record == null) {
      return _json({
        "error": {"error_message": "Domain not found"},
      });
    }
    return _json({
      "response": {...record, "smt_root": serverRoot},
    });
  }
}

String _word(int v) => v.toRadixString(16).padLeft(64, "0");

PivxNameResponse _json(Object o) => (status: 200, body: jsonEncode(o));

PivxNameResponse _result(String r) =>
    _json({"jsonrpc": "2.0", "id": 1, "result": r});

Matcher _throwsKind(PivxNameError kind) =>
    throwsA(isA<PivxNameException>().having((e) => e.kind, "kind", kind));

void main() {
  test("a name verified against the chain's current root", () async {
    final net = _Net();
    final result = await net.resolver().lookup("alexxiy.pivx");
    expect(result, isA<PivxNameVerified>());
    expect((result as PivxNameVerified).address, liveTarget);
    // three requests' worth: the server once, the contract under quorum
    expect(net.log.where((l) => l.startsWith("server")), hasLength(1));
    expect(net.log.where((l) => l.contains("8d39310a")), hasLength(2));
  });

  group("reads are pinned to one block", () {
    test(
      "the highest block two endpoints have reached, never latest",
      () async {
        final net = _Net(heights: [100, 105, 103, 90, 104]);
        final result = await net.resolver().lookup("alexxiy.pivx");
        expect(result, isA<PivxNameVerified>());
        final calls = net.log.where((l) => l.contains("eth_call"));
        expect(calls, isNotEmpty);
        // 104 = 0x68; behind-the-block endpoints fail and the next is asked
        expect(
          calls.every((l) => l.endsWith("@0x68")),
          isTrue,
          reason: "$calls",
        );
      },
    );

    // Endpoints and server behind together: nothing looks stale at "latest",
    // and the name's previous address would be paid.
    test("lagging endpoints can't make an old root look current", () async {
      final net = _Net(heights: [100, 100, 110, 110, 110]);
      net.roots[105] = _newerRoot;
      net.validFrom[_newerRoot] = 105;
      final result = await net.resolver().lookup("alexxiy.pivx");
      expect(result, isA<PivxNameIndexerBehind>());
    });
  });

  group("quorum", () {
    test("a lone dissenting endpoint stops the lookup", () async {
      final net = _Net();
      net.rpcs.values.elementAt(1).lieRoot = _olderRoot;
      await expectLater(
        net.resolver().lookup("alexxiy.pivx"),
        _throwsKind(PivxNameError.chainDisagreement),
      );
    });

    test(
      "a disagreement found while replacing a failed endpoint too",
      () async {
        final net = _Net();
        net.rpcs.values.elementAt(0).down = Exception("refused");
        net.rpcs.values.elementAt(2).lieRoot = _olderRoot;
        await expectLater(
          net.resolver().lookup("alexxiy.pivx"),
          _throwsKind(PivxNameError.chainDisagreement),
        );
      },
    );

    test("failing endpoints are replaced until two agree", () async {
      final net = _Net(heights: [100, 100, 100, 100, 100, 100]);
      final r = net.rpcs.values.toList();
      r[0].down = TimeoutException("No answer within 10 s");
      r[1].httpStatus = 429;
      r[2].rpcError = true;
      r[3].empty = true;
      final result = await net.resolver().lookup("alexxiy.pivx");
      expect(result, isA<PivxNameVerified>());
    });

    test("one answer is not enough", () async {
      final net = _Net();
      for (final r in net.rpcs.values.skip(1)) {
        r.httpStatus = 403;
      }
      final future = net.resolver().lookup("alexxiy.pivx");
      await expectLater(future, _throwsKind(PivxNameError.chainUnavailable));
      await future.catchError((Object e) {
        expect((e as PivxNameException).isTransient, isTrue);
        expect(e.message, contains("Only 1 of 5"));
        return const PivxNameNotRegistered("");
      });
    });

    test("too few endpoints configured, or the same one twice", () async {
      final net = _Net(heights: [100]);
      await expectLater(
        net.resolver().lookup("alexxiy.pivx"),
        _throwsKind(PivxNameError.unavailable),
      );
      final twice = _Net(heights: [100]);
      final resolver = PivxNameResolver(
        PivxNameService(
          indexer: twice.service.indexer,
          anchor: twice.service.anchor,
          rpcs: [twice.service.rpcs.first, twice.service.rpcs.first],
          epochs: const {1},
        ),
        transport: twice.transport,
      );
      await expectLater(
        resolver.lookup("alexxiy.pivx"),
        _throwsKind(PivxNameError.unavailable),
      );
    });

    test("malformed answers count as failures, not as answers", () async {
      final net = _Net();
      net.rpcs.values.first.lieRoot = "abc";
      final result = await net.resolver().lookup("alexxiy.pivx");
      expect(result, isA<PivxNameVerified>());
    });
  });

  group("a server out of step with the chain", () {
    // A proof against an earlier genuine root shows what the name pointed
    // to then. Never good enough to pay.
    test("behind: wait, even though its proof is genuine", () async {
      final net = _Net();
      net.roots[50] = _newerRoot;
      net.validFrom[_newerRoot] = 50;
      final result = await net.resolver().lookup("alexxiy.pivx");
      expect(result, isA<PivxNameIndexerBehind>());
      expect((result as PivxNameIndexerBehind).nameMissing, isFalse);
    });

    test("behind and missing the name: a recent registration", () async {
      final net = _Net();
      net.roots[50] = _newerRoot;
      net.validFrom[_newerRoot] = 50;
      final result = await net.resolver().lookup("newname.pivx");
      expect(result, isA<PivxNameIndexerBehind>());
      expect((result as PivxNameIndexerBehind).nameMissing, isTrue);
    });

    test("in step and missing the name: not registered", () async {
      final net = _Net();
      final result = await net.resolver().lookup("newname.pivx");
      expect(result, isA<PivxNameNotRegistered>());
    });

    test("a root the contract never accepted is refused", () async {
      final net = _Net();
      net.serverRoot = _unknownRoot;
      await expectLater(
        net.resolver().lookup("alexxiy.pivx"),
        _throwsKind(PivxNameError.unanchoredRoot),
      );
      // A clean "false" is an answer: two endpoints per check, one check per
      // attempt (and one recheck), no shopping for a "true".
      expect(net.log.where((l) => l.contains("30ef41b4")), hasLength(4));
    });

    test("ahead of the pinned block: looked at again later", () async {
      final net = _Net(heights: [105, 105, 105, 105, 105]);
      net.roots[0] = _olderRoot;
      net.roots[106] = liveRoot;
      net.validFrom[liveRoot] = 106;
      net.onUnknownRoot = () {
        // time passes: the anchoring transaction reaches the endpoints
        for (final r in net.rpcs.values) {
          r.height = 107;
        }
      };
      final result = await net.resolver().lookup("alexxiy.pivx");
      expect(result, isA<PivxNameVerified>());
    });

    test("caughtUp compares the server's root with the chain's", () async {
      final net = _Net();
      expect(await net.resolver().caughtUp(), isTrue);
      net.serverRoot = _olderRoot;
      expect(await net.resolver().caughtUp(), isFalse);
    });
  });

  test("a record that doesn't match its proof is refused", () async {
    final net = _Net();
    net.records["alexxiy.pivx"] = liveRecord({
      "target_address": otherShieldAddress,
    });
    await expectLater(
      net.resolver().lookup("alexxiy.pivx"),
      _throwsKind(PivxNameError.badRecord),
    );
  });

  test("an unreviewed epoch is refused", () async {
    final net = _Net()..epoch = 2;
    final future = net.resolver().lookup("alexxiy.pivx");
    await expectLater(future, _throwsKind(PivxNameError.unreviewedEpoch));
  });

  group("the server's answers are data", () {
    test("its error text never picks the kind of failure", () async {
      for (final text in [
        "EVM RPC endpoints disagree",
        "Failed to fetch",
        "NetworkError, timeout, connection reset",
        "Domain not found ",
      ]) {
        final net = _Net()..serverError = text;
        await expectLater(
          net.resolver().lookup("alexxiy.pivx"),
          _throwsKind(PivxNameError.indexerError),
          reason: text,
        );
      }
    });

    test("its error text is cleaned and cut short", () async {
      final net = _Net()
        ..serverError = "<img src=x onerror=alert(1)>\u202e\n${"x" * 5000}";
      try {
        await net.resolver().lookup("alexxiy.pivx");
        fail("should throw");
      } on PivxNameException catch (e) {
        expect(e.isTransient, isFalse);
        expect(e.detail!.length, lessThanOrEqualTo(201));
        expect(e.detail, isNot(contains("\u202e")));
        expect(e.detail, isNot(contains("\n")));
      }
    });

    test("a malformed root never reaches the contract", () async {
      final net = _Net()..serverRoot = "not-a-root";
      await expectLater(
        net.resolver().lookup("alexxiy.pivx"),
        _throwsKind(PivxNameError.indexerError),
      );
      expect(net.log.where((l) => l.contains("30ef41b4")), isEmpty);
      // ...from getRoot either
      final missing = _Net()..serverRoot = "zz";
      await expectLater(
        missing.resolver().lookup("newname.pivx"),
        _throwsKind(PivxNameError.indexerError),
      );
    });

    test("a non-JSON answer", () async {
      final net = _Net()..serverBody = "<html>502</html>";
      await expectLater(
        net.resolver().lookup("alexxiy.pivx"),
        _throwsKind(PivxNameError.indexerError),
      );
    });

    test("no answer at all is worth waiting out", () async {
      final net = _Net()..serverDown = true;
      final future = net.resolver().lookup("alexxiy.pivx");
      await expectLater(future, _throwsKind(PivxNameError.indexerUnreachable));
      await future.catchError((Object e) {
        expect((e as PivxNameException).isTransient, isTrue);
        return const PivxNameNotRegistered("");
      });
    });
  });

  test("only valid names are looked up", () async {
    final net = _Net();
    await expectLater(
      net.resolver().lookup("Alexxiy.pivx"),
      throwsArgumentError,
    );
    await expectLater(
      net.resolver().lookup("a/../b.pivx"),
      throwsArgumentError,
    );
    expect(net.log, isEmpty);
  });

  test("names exist on mainnet only", () {
    expect(
      PivxNameService.forCoin(Pivx(CryptoCurrencyNetwork.main)),
      isNotNull,
    );
    expect(PivxNameService.forCoin(Pivx(CryptoCurrencyNetwork.test)), isNull);
  });

  test("mainnet trusts epoch 1 and the coming epoch 2", () {
    // The prover v0.2.1 rules change moves the contract to epoch 2: this
    // release has to work on both sides of its activation.
    expect(PivxNameService.mainnet.epochs, containsAll(<int>[1, 2]));
  });
}
