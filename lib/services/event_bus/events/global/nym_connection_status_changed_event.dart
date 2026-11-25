import '../../../../utilities/logger.dart';
import 'tor_connection_status_changed_event.dart';

/// The Nym mixnet client's status changed. It has the same three states
/// as Tor, so it shares [TorConnectionStatus].
class NymConnectionStatusChangedEvent {
  NymConnectionStatusChangedEvent(this.newStatus, this.message) {
    Logging.instance.d("Nym status changed to $newStatus ($message)");
  }

  final TorConnectionStatus newStatus;
  final String message;
}
