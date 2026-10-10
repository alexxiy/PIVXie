import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_tx_parser.dart';

/// Little-endian bytes of [v] over [n] bytes.
List<int> le(int v, int n) => [
  for (int i = 0; i < n; i++) (v >> (8 * i)) & 0xff,
];

Uint8List tx({
  required List<int> version,
  required List<int> values,
  List<int> tail = const [],
}) {
  final script = List.filled(25, 0x76); // P2PKH-sized dummy script
  return Uint8List.fromList([
    ...version,
    2, // two inputs
    for (int i = 0; i < 2; i++) ...[
      ...List.filled(32, i + 1), // prev txid
      ...le(i, 4), // prev vout
      107, ...List.filled(107, 0xaa), // scriptSig
      ...le(0xffffffff, 4),
    ],
    values.length,
    for (final v in values) ...[...le(v, 8), script.length, ...script],
    ...le(0, 4), // nLockTime
    ...tail,
  ]);
}

void main() {
  test("output values of a legacy transaction", () {
    final raw = tx(version: le(1, 4), values: [1000000000000, 12345]);
    expect(pivxTxOutputValues(raw), [
      BigInt.from(1000000000000),
      BigInt.from(12345),
    ]);
  });

  test(
    "output values of a Sapling (v3) transaction ignore the shield data",
    () {
      final raw = tx(
        version: [3, 0, 0, 0], // nVersion 3, nType 0
        values: [5000],
        tail: [1, ...List.filled(200, 0x42)], // sapData
      );
      expect(pivxTxOutputValues(raw), [BigInt.from(5000)]);
    },
  );

  test("a truncated transaction is rejected", () {
    final raw = tx(version: le(1, 4), values: [1, 2, 3]);
    expect(
      () => pivxTxOutputValues(Uint8List.sublistView(raw, 0, raw.length - 40)),
      throwsA(anything),
    );
  });
}
