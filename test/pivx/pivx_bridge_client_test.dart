import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';

/// A local server answering `/getblockcount` with [codes] in turn (the
/// last one from then on). Returns the server and how many requests came.
Future<(HttpServer, List<int>)> _serve(List<int> codes) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = [0];
  server.listen((request) async {
    final code = codes[min(requests[0]++, codes.length - 1)];
    request.response
      ..statusCode = code
      ..write(code == 200 ? "123" : '{"error":"the node is busy, try again"}');
    await request.response.close();
  });
  return (server, requests);
}

PivxBridgeClient _client(HttpServer server) =>
    PivxBridgeClient(baseUri: Uri.parse("http://127.0.0.1:${server.port}"));

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
}
