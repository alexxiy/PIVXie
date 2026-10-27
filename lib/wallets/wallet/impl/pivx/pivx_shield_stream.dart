import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../../utilities/extensions/extensions.dart';

/// Upper bound of a stream packet; larger lengths mean a broken or
/// hostile stream (PIVX transactions are far smaller).
const _kMaxPacket = 4 * 1024 * 1024;

/// One block from the bridge's shield stream. [time] is 0 in the compact
/// format, which doesn't carry it.
typedef PivxShieldBlock = ({int height, int time, List<String> txs});

/// Packet types of the bridge's shield streams.
const _kBlockPacket = 0x5d;
const _kRawTxPacket = 0x03;
const _kCompactTxPacket = 0x04;

/// Parse the bridge's shield stream: packets of `[u32 LE length][payload]`.
///
/// * `pivx` format (default): raw v3 transactions (first byte 0x03), each
///   block closed by a footer `[0x5d][height u32 LE][time u32 LE]`.
/// * `compact` format: each block opened by a header
///   `[0x5d][height u32 LE]`, then compact transactions (first byte 0x04)
///   with only the Sapling parts a wallet scans. A block ends at the next
///   header or at the end of the stream.
Stream<PivxShieldBlock> parsePivxShieldStream(Stream<List<int>> bytes) async* {
  var buf = Uint8List(0);
  var off = 0;
  var txs = <String>[];
  // Height of the open compact block.
  int? open;

  await for (final chunk in bytes) {
    final rest = buf.length - off;
    buf = Uint8List(rest + chunk.length)
      ..setRange(0, rest, buf, off)
      ..setRange(rest, rest + chunk.length, chunk);
    off = 0;

    while (buf.length - off >= 4) {
      final len = ByteData.sublistView(
        buf,
        off,
        off + 4,
      ).getUint32(0, Endian.little);
      if (len > _kMaxPacket) {
        throw FormatException("Shield packet too large ($len bytes)");
      }
      if (buf.length - off - 4 < len) break;
      final packet = Uint8List.sublistView(buf, off + 4, off + 4 + len);
      off += 4 + len;
      if (packet.isEmpty) throw const FormatException("Empty shield packet");
      final view = ByteData.sublistView(packet);
      switch (packet[0]) {
        case _kBlockPacket when packet.length == 9 && open == null:
          yield (
            height: view.getUint32(1, Endian.little),
            time: view.getUint32(5, Endian.little),
            txs: txs,
          );
          txs = <String>[];
        case _kBlockPacket when packet.length == 5 && open != null:
          yield (height: open, time: 0, txs: txs);
          txs = <String>[];
          open = view.getUint32(1, Endian.little);
        case _kBlockPacket when packet.length == 5 && txs.isEmpty:
          open = view.getUint32(1, Endian.little);
        case _kBlockPacket:
          throw const FormatException("Unexpected block packet");
        case _kRawTxPacket || _kCompactTxPacket:
          txs.add(packet.toHex);
        default:
          throw FormatException("Unexpected shield packet type ${packet[0]}");
      }
    }
  }
  if (buf.length - off != 0) {
    throw const FormatException("Shield stream ended mid-packet");
  }
  if (open != null) {
    yield (height: open, time: 0, txs: txs);
  } else if (txs.isNotEmpty) {
    throw const FormatException("Shield stream ended mid-block");
  }
}

/// A compact stream block that doesn't match the chain: the scan reads
/// it again from full transactions.
class PivxCompactStreamMismatch implements Exception {
  const PivxCompactStreamMismatch(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Run [attempt] (one pass over the shield stream) again after a network
/// error or a [PivxCompactStreamMismatch], as long as passes keep moving
/// [position] (the last saved block): a full scan downloads hundreds of
/// MB, and a dropped or stalled connection shouldn't throw that away.
/// Fails after [maxFailures] passes in a row that saved nothing.
Future<void> retryShieldStream({
  required Future<void> Function() attempt,
  required int Function() position,
  int maxFailures = 3,
  Duration Function(int failures)? delay,
  void Function(Object error)? onRetry,
}) async {
  var failures = 0;
  while (true) {
    final from = position();
    try {
      return await attempt();
    } catch (e) {
      if (e is! SocketException &&
          e is! TimeoutException &&
          e is! HttpException &&
          e is! TlsException &&
          e is! PivxCompactStreamMismatch) {
        rethrow;
      }
      failures = position() > from ? 1 : failures + 1;
      if (failures >= maxFailures) rethrow;
      onRetry?.call(e);
      await Future<void>.delayed(
        delay?.call(failures) ?? Duration(seconds: 3 * failures),
      );
    }
  }
}
