// Starts a legacy masternode with a broadcast built by
// pivxMasternodeBroadcast and relayed through pivx-bridge, against a
// regtest node and a masternode server running with PIVX_MN_KEY.
//
// Run on the build VM (see /root/work/mn_setup.sh for the server):
//   PIVX_BRIDGE=http://127.0.0.1:3000 \
//   PIVX_CLI="/opt/pivx/bin/pivx-cli -datadir=/srv/pivx-regtest -conf=/srv/pivx-regtest/pivx.conf" \
//   PIVX_MN_KEY=$(cat /root/work/mn0.key) PIVX_MN_SERVICE=127.0.0.10:51476 \
//   (IPv6 server: PIVX_MN_SERVICE="[::1]:51476") \
//   flutter test --concurrency=1 test/pivx/pivx_masternode_start_regtest_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';
import 'package:paymint/wallets/wallet/impl/pivx_wallet.dart';

Future<String> _cli(List<String> args) async {
  final cli = Platform.environment["PIVX_CLI"]!.split(" ");
  final r = await Process.run(cli.first, [...cli.skip(1), ...args]);
  if (r.exitCode != 0) throw Exception("pivx-cli ${args.first}: ${r.stderr}");
  return (r.stdout as String).trim();
}

void main() {
  final env = Platform.environment;
  final skip =
      env["PIVX_BRIDGE"] == null ||
          env["PIVX_CLI"] == null ||
          env["PIVX_MN_KEY"] == null ||
          env["PIVX_MN_SERVICE"] == null
      ? "PIVX_BRIDGE, PIVX_CLI, PIVX_MN_KEY or PIVX_MN_SERVICE not set"
      : null;

  test("relayed masternode broadcast starts the masternode", () async {
    await coinlib.loadCoinlib();
    final bridge = PivxBridgeClient(baseUri: Uri.parse(env["PIVX_BRIDGE"]!));

    // Regtest collateral: 100 PIV with 1 confirmation.
    final address = await _cli(["getnewaddress"]);
    final txid = await _cli(["sendtoaddress", address, "100"]);
    await _cli(["generate", "1"]);
    final tx = jsonDecode(await _cli(["getrawtransaction", txid, "1"])) as Map;
    final vout = (tx["vout"] as List)
        .cast<Map>()
        .firstWhere((o) => o["value"] == 100)["n"] as int;
    // Keep the node's other sends (and the other suites) off it.
    await _cli([
      "lockunspent",
      "false",
      "true",
      jsonEncode([
        {"txid": txid, "vout": vout},
      ]),
    ]);
    final collateralKey = coinlib.WIF.fromString(
      await _cli(["dumpprivkey", address]),
      version: 239,
    ).privkey;
    final masternodeKey = coinlib.WIF.fromString(
      env["PIVX_MN_KEY"]!,
      version: 239,
    ).privkey;

    final height = await bridge.getBlockCount();
    // "1.2.3.4:port" or "[v6]:port"
    final service = env["PIVX_MN_SERVICE"]!;
    final i = service.lastIndexOf(":");
    final port = int.parse(service.substring(i + 1));
    final ip = InternetAddress(
      service.substring(0, i).replaceAll(RegExp(r"[\[\]]"), ""),
    ).rawAddress;
    final mnb = pivxMasternodeBroadcast(
      txid: txid,
      vout: vout,
      service: Uint8List.fromList([
        if (ip.length == 4) ...[...List.filled(10, 0), 0xff, 0xff],
        ...ip,
        port >> 8,
        port & 0xff,
      ]),
      collateralKey: collateralKey,
      masternodeKey: masternodeKey,
      blockHash: await bridge.blockHash(height - 12),
      sigTime: DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
      protocolVersion: (await bridge.protocolVersion())!,
    ).toHex;

    final decoded =
        jsonDecode(await _cli(["decodemasternodebroadcast", mnb])) as Map;
    expect(decoded["vin"], "COutPoint(${txid.substring(0, 10)}, $vout)");
    expect(decoded["addr"], service);

    final answer = await bridge.relayMasternodeBroadcast(mnb);
    expect(answer, contains("Masternode broadcast sent"));

    String? status;
    for (int i = 0; i < 30 && status == null; i++) {
      final list = await bridge.listMasternodes(txid);
      for (final e in list) {
        final m = e as Map;
        if (m["txhash"] == txid && m["outidx"] == vout) {
          status = m["status"] as String;
        }
      }
      if (status == null) await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(status, anyOf("PRE_ENABLED", "ENABLED"));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
