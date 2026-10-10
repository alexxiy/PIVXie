import 'dart:typed_data';

import '../../../../utilities/extensions/extensions.dart';

/// Upper bound of a stream packet; larger lengths mean a broken or
/// hostile stream (PIVX transactions are far smaller).
const _kMaxPacket = 4 * 1024 * 1024;

/// One block from the bridge's shield stream.
typedef PivxShieldBlock = ({int height, int time, List<String> txs});

/// Parse the bridge's default (`pivx`) shield stream: packets of
/// `[u32 LE length][payload]`, where a payload is either a raw v3
/// transaction (first byte 0x03) or a block footer
/// `[0x5d][height u32 LE][time u32 LE]` that closes the preceding txs.
Stream<PivxShieldBlock> parsePivxShieldStream(Stream<List<int>> bytes) async* {
  var buf = Uint8List(0);
  var off = 0;
  var txs = <String>[];

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
      if (packet[0] == 0x5d) {
        if (packet.length < 9)
          throw const FormatException("Short block footer");
        final view = ByteData.sublistView(packet);
        yield (
          height: view.getUint32(1, Endian.little),
          time: view.getUint32(5, Endian.little),
          txs: txs,
        );
        txs = <String>[];
      } else if (packet[0] == 0x03) {
        txs.add(packet.toHex);
      } else {
        throw FormatException("Unexpected shield packet type ${packet[0]}");
      }
    }
  }
  if (buf.length - off != 0 || txs.isNotEmpty) {
    throw const FormatException("Shield stream ended mid-block");
  }
}
