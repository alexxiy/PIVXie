import 'dart:io';

import 'package:isar_community/isar.dart';

import '../db/hive/db.dart';
import '../db/isar/main_db.dart';
import '../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../models/isar/models/contact_entry.dart';
import '../models/isar/models/isar_models.dart';
import '../services/node_service.dart';
import '../services/wallets.dart';
import '../wallets/isar/models/wallet_info.dart';
import '../wallets/isar/models/wallet_info_meta.dart';
import 'flutter_secure_storage_interface.dart';
import 'logger.dart';
import 'prefs.dart';
import 'stack_file_system.dart';

/// Deletes everything the app keeps: wallets, keys, history, the address
/// book, settings, shield data and the Sapling parameters. Used by
/// "Forgot password" on desktop and "Delete account" on iOS.
abstract final class AppDataWipe {
  /// The folders the app makes in its data folder. Only these go: the
  /// data folder can be one the user picked (`-d`) and holds other files.
  static const _appFolders = [
    "isar",
    "hive",
    "pivx_shield",
    "sapling-params",
    "themes",
    "tor",
  ];

  /// Desktop: delete the app's folders, then quit. The databases are
  /// closed first: Windows can't delete open files, and on Linux and macOS
  /// a deleted database left open keeps taking writes (new wallets) that
  /// are gone at the next start.
  static Future<Never> wipeDesktopAndExit() async {
    final root = await StackFileSystem.applicationRootDirectory();
    await Isar.getInstance("desktopStore")?.close();
    await Isar.getInstance("wallet_data")?.close();
    await DB.instance.hive.close();
    for (final name in _appFolders) {
      final dir = Directory("${root.path}${Platform.pathSeparator}$name");
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
      } catch (e) {
        // Still in use (Tor's files on Windows): the rest still goes.
        Logging.instance.w("Could not delete ${dir.path}: $e");
      }
    }
    exit(0);
  }

  /// iOS: delete every wallet (with its keys and data) and everything
  /// else, while the app keeps running.
  static Future<void> wipeInApp({
    required Wallets wallets,
    required SecureStorageInterface secureStorage,
    required NodeService nodeService,
  }) async {
    final isar = MainDB.instance.isar;
    for (final info in await isar.walletInfo.where().findAll()) {
      await wallets.deleteWallet(info, secureStorage);
    }
    // Whatever deleting by wallet left (rows of wallets deleted earlier).
    await isar.writeTxn(() async {
      await isar.transactions.clear();
      await isar.transactionV2s.clear();
      await isar.transactionNotes.clear();
      await isar.utxos.clear();
      await isar.addresses.clear();
      await isar.addressLabels.clear();
      await isar.contactEntrys.clear();
      await isar.walletInfo.clear();
      await isar.walletInfoMeta.clear();
    });
    // The PIN and anything else kept in the keychain (which outlives the
    // app on iOS).
    for (final key in await secureStorage.keys) {
      await secureStorage.delete(key: key);
    }
    final root = await StackFileSystem.applicationRootDirectory();
    for (final name in const ["pivx_shield", "sapling-params"]) {
      final dir = Directory("${root.path}/$name");
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
    if (!await DB.instance.deleteEverything()) {
      throw Exception("Deleting the settings failed");
    }
    // Start over as on a first start: empty settings, default nodes.
    await DB.instance.init();
    await Prefs.instance.reload();
    await nodeService.updateDefaults();
  }
}
