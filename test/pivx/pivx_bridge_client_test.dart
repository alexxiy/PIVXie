import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/node_model.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';

/// A local server answering every request with [codes] in turn (the last
/// one from then on), and [body] if given. Returns the server and how many
/// requests came.
Future<(HttpServer, List<int>)> _serve(List<int> codes, {String? body}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = [0];
  server.listen((request) async {
    final code = codes[min(requests[0]++, codes.length - 1)];
    request.response
      ..statusCode = code
      ..write(
        body ??
            (code == 200 ? "123" : '{"error":"the node is busy, try again"}'),
      );
    await request.response.close();
  });
  return (server, requests);
}

PivxBridgeClient _client(HttpServer server) =>
    PivxBridgeClient(baseUri: Uri.parse("http://127.0.0.1:${server.port}"));

NodeModel _node(int port) => NodeModel(
  host: "127.0.0.1",
  port: port,
  name: "local",
  id: "local",
  useSSL: false,
  coinName: "pivx",
  torEnabled: false,
  clearnetEnabled: true,
  isPrimary: true,
);

/// What restoring through the bridge on [port] would tell the user after
/// [call] fails.
Future<String> _restoreText(
  int port,
  Future<Object?> Function(PivxBridgeClient) call,
) async {
  try {
    await call(PivxBridgeClient(baseUri: Uri.parse("http://127.0.0.1:$port")));
  } catch (e) {
    return restoreFailureText(e, _node(port));
  }
  fail("the call didn't fail");
}

void main() {
  group("a busy bridge (503)", () {
    test("is asked again", () async {
      final (server, requests) = await _serve([503, 200]);
      addTearDown(() => server.close(force: true));
      expect(await _client(server).getBlockCount(), 123);
      expect(requests[0], 2);
    });

    test("fails after two more tries", () async {
      final (server, requests) = await _serve([503]);
      addTearDown(() => server.close(force: true));
      await expectLater(
        _client(server).getBlockCount(),
        throwsA(
          isA<PivxBridgeException>()
              .having((e) => e.statusCode, "statusCode", 503)
              .having((e) => e.message, "message", contains("try again")),
        ),
      );
      expect(requests[0], 3);
    });
  });

  test("other errors are not asked again", () async {
    final (server, requests) = await _serve([500]);
    addTearDown(() => server.close(force: true));
    await expectLater(
      _client(server).getBlockCount(),
      throwsA(isA<PivxBridgeException>()),
    );
    expect(requests[0], 1);
  });

  group("a failed restore says", () {
    test("the node has no address index", () async {
      final (server, _) = await _serve([404], body: "");
      addTearDown(() => server.close(force: true));
      final text = await _restoreText(server.port, (c) => c.status());
      expect(text, contains("127.0.0.1:${server.port}"));
      expect(text, contains("no address index"));
    });

    test("the node's own error", () async {
      final (server, _) = await _serve([500], body: '{"error":"bad xpub"}');
      addTearDown(() => server.close(force: true));
      final text = await _restoreText(server.port, (c) => c.getBlockCount());
      expect(text, contains("127.0.0.1:${server.port}"));
      expect(text, contains("bad xpub"));
    });

    test("the node didn't answer", () async {
      final (server, _) = await _serve([200]);
      final port = server.port;
      await server.close(force: true);
      final text = await _restoreText(port, (c) => c.getBlockCount());
      expect(text, startsWith("Couldn't reach 127.0.0.1:$port."));
    });

    test("anything else as it is", () {
      expect(
        restoreFailureText(StateError("odd"), _node(80)),
        "Bad state: odd",
      );
    });
  });

  group("shield scan requests", () {
    late HttpServer server;
    final requests = <Uri>[];

    setUp(() async {
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add(request.uri);
        request.response.write(switch (request.uri.path) {
          "/getblockhash" => '"00ab"',
          "/getblock" => '{"tx":["t1","t2"],"finalsaplingroot":"r1"}',
          _ => "",
        });
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
    });

    test("a block's txids and Sapling root come from getblock", () async {
      final client = _client(server);
      expect(await client.blockTxids(7), ["t1", "t2"]);
      expect(await client.finalSaplingRoot(7), "r1");
      expect(requests.map((u) => "${u.path} ${u.queryParameters["params"]}"), [
        "/getblockhash 7",
        "/getblock 00ab,1",
        "/getblockhash 7",
        "/getblock 00ab,1",
      ]);
    });

    test("the compact stream is asked for by format", () async {
      final client = _client(server);
      await client.shieldData(5, compact: true).drain<void>();
      await client.shieldData(5).drain<void>();
      expect(requests.map((u) => u.queryParameters), [
        {"startBlock": "5", "format": "compact"},
        {"startBlock": "5"},
      ]);
    });
  });
}
