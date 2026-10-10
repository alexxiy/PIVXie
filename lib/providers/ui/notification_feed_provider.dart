import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/notification_feed_entry.dart';
import '../global/notifications_provider.dart';

/// The merged notification feed, newest first, shared by the mobile and
/// desktop notifications views. Pass a walletId to scope the list to that
/// wallet's notifications; null is the global feed.
final pNotificationFeed = Provider.autoDispose
    .family<List<NotificationFeedEntry>, String?>((ref, walletId) {
      final all = ref.watch(
        notificationsProvider.select((value) => value.notifications),
      );
      final hive = walletId == null
          ? all
          : all
                .where((element) => element.walletId == walletId)
                .toList(growable: false);
      return mergeNotificationFeed(hive);
    });
