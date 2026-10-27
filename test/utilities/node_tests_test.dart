import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/l10n/l10n.dart';
import 'package:paymint/models/node_model.dart';
import 'package:paymint/utilities/test_node_connection.dart';

void main() {
  final node = NodeModel(
    host: "https://eu.example",
    port: 443,
    name: "EU",
    id: "eu",
    useSSL: true,
    coinName: "pivx",
    torEnabled: true,
    clearnetEnabled: true,
    isPrimary: false,
  );

  test("answer times: milliseconds, then seconds", () {
    expect(answerTime(const Duration(milliseconds: 142)), "142 ms");
    expect(answerTime(const Duration(milliseconds: 999)), "999 ms");
    expect(answerTime(const Duration(milliseconds: 1449)), "1.4 s");
    expect(answerTime(const Duration(milliseconds: 12345)), "12 s");
  });

  test("a result in a few words", () {
    const time = Duration(milliseconds: 80);
    expect(NodeTestResult(time: time).short, "80 ms");
    expect(
      NodeTestResult(time: time, problem: l10n.nodeUnreachable).short,
      l10n.nodeNoAnswer,
    );
    expect(
      NodeTestResult(time: time, problem: l10n.nodeUseOnlyOverTor).short,
      l10n.nodeOnlyTor,
    );
    expect(
      NodeTestResult(time: time, problem: l10n.nodeUseWithoutTor).short,
      l10n.nodeOnlyWithoutTor,
    );
    expect(
      NodeTestResult(time: time, problem: l10n.bridgeNoAddressIndexShort).short,
      l10n.nodeCheckFailed,
    );
  });

  test("connection level by answer time, none when failed", () {
    int level(int ms, [String? problem]) => NodeTestResult(
      time: Duration(milliseconds: ms),
      problem: problem,
    ).level;
    expect(level(120), 4);
    expect(level(300), 3);
    expect(level(999), 3);
    expect(level(1000), 2);
    expect(level(2999), 2);
    expect(level(3000), 1);
    expect(level(19000), 1);
    expect(level(50, l10n.nodeUnreachable), 0);
  });

  test("a node's test runs once at a time and its result stays", () async {
    final tests = NodeTests();
    var notified = 0;
    tests.addListener(() => notified++);
    final answer = Completer<String?>();
    var calls = 0;
    Future<String?> test() {
      calls++;
      return answer.future;
    }

    final first = tests.run(node, test);
    final second = tests.run(node, test);
    expect(calls, 1);
    expect(tests.isTesting(node.id), isTrue);
    expect(tests.resultFor(node.id), isNull);

    answer.complete(null);
    final result = await first;
    expect(await second, same(result));
    expect(result.passed, isTrue);
    expect(tests.isTesting(node.id), isFalse);
    expect(tests.resultFor(node.id), same(result));
    expect(notified, 2);

    // A test that throws counts as no answer.
    final failed = await tests.run(node, () async => throw Exception("x"));
    expect(failed.problem, l10n.nodeUnreachable);
    expect(tests.resultFor(node.id), same(failed));
  });
}
