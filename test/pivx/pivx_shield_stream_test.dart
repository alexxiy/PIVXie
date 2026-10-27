import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_shield_stream.dart';

/// A stream packet: `[u32 LE length][payload]`.
List<int> packet(List<int> payload) => [...le(payload.length, 4), ...payload];

/// Little-endian bytes of [v] over [n] bytes.
List<int> le(int v, int n) => [
  for (int i = 0; i < n; i++) (v >> (8 * i)) & 0xff,
];

/// Blocks of [bytes] as "height time txs", fed in [chunk] byte pieces.
Future<List<String>> parse(List<int> bytes, {int chunk = 7}) =>
    parsePivxShieldStream(
      Stream.fromIterable([
        for (int i = 0; i < bytes.length; i += chunk)
          bytes.sublist(i, (i + chunk).clamp(0, bytes.length)),
      ]),
    ).map((b) => "${b.height} ${b.time} ${b.txs.join(",")}").toList();

void main() {
  group("parsePivxShieldStream", () {
    test("pivx format: footers close their blocks", () async {
      final blocks = await parse([
        ...packet([0x03, 1, 2]),
        ...packet([0x03, 3]),
        ...packet([0x5d, ...le(100, 4), ...le(1700000000, 4)]),
        ...packet([0x03, 4]),
        ...packet([0x5d, ...le(105, 4), ...le(1700000300, 4)]),
      ]);
      expect(blocks, ["100 1700000000 030102,0303", "105 1700000300 0304"]);
    });

    test("compact format: headers open their blocks", () async {
      final blocks = await parse([
        ...packet([0x5d, ...le(100, 4)]),
        ...packet([0x04, 0, 1, 9]),
        ...packet([0x04, 1, 0, 8]),
        ...packet([0x5d, ...le(101, 4)]),
        ...packet([0x5d, ...le(105, 4)]),
        ...packet([0x04, 0, 1, 7]),
      ]);
      expect(blocks, ["100 0 04000109,04010008", "101 0 ", "105 0 04000107"]);
    });

    test("broken streams are refused", () async {
      final broken = {
        "cut packet": [
          ...packet([0x03, 1, 2]).take(5),
        ],
        "txs without a footer": packet([0x03, 1]),
        "txs before a compact header": [
          ...packet([0x04, 0, 0]),
          ...packet([0x5d, ...le(100, 4)]),
        ],
        "a footer in a compact block": [
          ...packet([0x5d, ...le(100, 4)]),
          ...packet([0x5d, ...le(100, 4), ...le(0, 4)]),
        ],
        "a short block packet": packet([0x5d, 1, 2]),
        "an unknown packet": packet([0x07, 1]),
        "an empty packet": packet([]),
      };
      for (final MapEntry(:key, :value) in broken.entries) {
        await expectLater(parse(value), throwsFormatException, reason: key);
      }
    });
  });

  group("retryShieldStream", () {
    test("resumes while each pass saves blocks", () async {
      var saved = 0;
      var passes = 0;
      await retryShieldStream(
        position: () => saved,
        delay: (_) => Duration.zero,
        attempt: () async {
          passes++;
          saved += 200;
          // Five drops, each after a saved batch: more than maxFailures,
          // but none in a row without progress.
          if (passes <= 5) throw const SocketException("reset");
        },
      );
      expect(passes, 6);
      expect(saved, 1200);
    });

    test("gives up after passes in a row that save nothing", () async {
      var passes = 0;
      final retried = <Object>[];
      await expectLater(
        retryShieldStream(
          position: () => 0,
          delay: (_) => Duration.zero,
          onRetry: retried.add,
          attempt: () async {
            passes++;
            throw TimeoutException("no data");
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(passes, 3);
      expect(retried, hasLength(2));
    });

    test("counts failures again after a pass that saved blocks", () async {
      var saved = 0;
      var passes = 0;
      await expectLater(
        retryShieldStream(
          position: () => saved,
          delay: (_) => Duration.zero,
          attempt: () async {
            passes++;
            // Pass 2 saves a batch before dropping; the rest save nothing.
            if (passes == 2) saved += 200;
            throw const HttpException("Connection closed");
          },
        ),
        throwsA(isA<HttpException>()),
      );
      // 1 (no save), 2 (saved: count back to 1), 3, then 4 hits the limit.
      expect(passes, 4);
    });

    test("a compact mismatch is read again", () async {
      var passes = 0;
      await retryShieldStream(
        position: () => 0,
        delay: (_) => Duration.zero,
        attempt: () async {
          if (++passes == 1) {
            throw const PivxCompactStreamMismatch("no match");
          }
        },
      );
      expect(passes, 2);
    });

    test("other errors fail at once", () async {
      var passes = 0;
      await expectLater(
        retryShieldStream(
          position: () => 0,
          delay: (_) => Duration.zero,
          attempt: () async {
            passes++;
            throw const FormatException("Unexpected shield packet type 7");
          },
        ),
        throwsA(isA<FormatException>()),
      );
      expect(passes, 1);
    });
  });
}
