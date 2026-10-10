import '../models/notification_model.dart';

sealed class NotificationFeedEntry {
  DateTime get date;
}

class HiveFeedEntry extends NotificationFeedEntry {
  HiveFeedEntry(this.model);
  final NotificationModel model;
  @override
  DateTime get date => model.date;
}

List<NotificationFeedEntry> mergeNotificationFeed(
  List<NotificationModel> hive,
) {
  return <NotificationFeedEntry>[...hive.map(HiveFeedEntry.new)]
    ..sort((a, b) => b.date.compareTo(a.date));
}
