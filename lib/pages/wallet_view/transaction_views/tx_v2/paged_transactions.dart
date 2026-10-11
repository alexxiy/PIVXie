import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:isar_community/isar.dart';

import '../../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../../utilities/logger.dart';

/// A wallet's transactions, newest first, loaded from the database a
/// page at a time: [loadMore] when the list nears its end. Stays current
/// while the database changes, keeping as many rows as were loaded.
///
/// With [where], rows are scanned in chunks and only matches are kept,
/// so searches and filters also load by portions.
class PagedTransactions extends ChangeNotifier {
  PagedTransactions({
    required Isar isar,
    required this.walletId,
    bool Function(TransactionV2 tx)? where,
    this.pageSize = 50,
  }) : _isar = isar,
       _where = where {
    _subscription = _isar.transactionV2s.watchLazy().listen((_) {
      // A sync writes in bursts; reload once it settles.
      _reloadTimer?.cancel();
      _reloadTimer = Timer(const Duration(milliseconds: 250), _reload);
    });
    unawaited(loadMore());
  }

  final Isar _isar;
  final String walletId;
  final int pageSize;
  bool Function(TransactionV2 tx)? _where;

  late final StreamSubscription<void> _subscription;
  Timer? _reloadTimer;
  bool _disposed = false;

  /// Scan chunk when filtering: more rows than a page, as most may not
  /// match.
  static const _scanChunk = 200;

  List<TransactionV2> _items = const [];
  List<TransactionV2> get items => _items;

  /// Rows of the wallet read so far (matching or not).
  int _scanned = 0;

  bool _hasMore = true;
  bool get hasMore => _hasMore;

  bool _loaded = false;

  /// Whether the first page is in.
  bool get loaded => _loaded;

  /// Serialises loads; a newer generation drops older results.
  Future<void> _queue = Future.value();
  int _generation = 0;

  /// Newest first. Blocks can share a timestamp (several mined within a
  /// second, as on regtest): the higher block comes first.
  Query<TransactionV2> _query(int offset, int limit) => _isar.transactionV2s
      .where()
      .walletIdEqualToAnyTimestamp(walletId)
      .sortByTimestampDesc()
      .thenByHeightDesc()
      .offset(offset)
      .limit(limit)
      .build();

  bool _loadingMore = false;

  /// Load the next page (no-op when everything is loaded or a page is
  /// already on its way: list rows near the end all ask for more).
  Future<void> loadMore() {
    if (_loadingMore || !_hasMore) return Future.value();
    _loadingMore = true;
    return _enqueue(() async {
      try {
        if (!_hasMore) return;
        await _fill(
          _items.length + pageSize,
          _generation,
          base: _items,
          scanned: _scanned,
        );
      } finally {
        _loadingMore = false;
      }
    });
  }

  /// Change the filter and start over from the newest row. The current
  /// rows stay visible until the new ones are in.
  void setWhere(bool Function(TransactionV2 tx)? where) {
    _where = where;
    final generation = ++_generation;
    unawaited(
      _enqueue(() => _fill(pageSize, generation, base: const [], scanned: 0)),
    );
  }

  /// Read rows after the first [scanned] until [target] matches (on top
  /// of [base]) are loaded or the wallet's rows run out.
  Future<void> _fill(
    int target,
    int generation, {
    required List<TransactionV2> base,
    required int scanned,
  }) async {
    final items = [...base];
    var hasMore = true;
    while (items.length < target) {
      final chunk = _where == null ? target - items.length : _scanChunk;
      final rows = await _query(scanned, chunk).findAll();
      if (generation != _generation || _disposed) return;
      scanned += rows.length;
      items.addAll(_where == null ? rows : rows.where(_where!));
      if (rows.length < chunk) {
        hasMore = false;
        break;
      }
    }
    _items = List.unmodifiable(items);
    _scanned = scanned;
    _hasMore = hasMore;
    _loaded = true;
    notifyListeners();
  }

  Future<void> _reload() => _enqueue(() async {
    final target = _items.length < pageSize ? pageSize : _items.length;
    await _fill(target, ++_generation, base: const [], scanned: 0);
  });

  Future<void> _enqueue(Future<void> Function() task) => _queue = _queue
      .then((_) => _disposed ? null : task())
      .catchError((Object e, StackTrace s) {
        Logging.instance.e(
          "Loading transactions failed",
          error: e,
          stackTrace: s,
        );
      });

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reloadTimer?.cancel();
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
