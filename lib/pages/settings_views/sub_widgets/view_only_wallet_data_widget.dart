import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../models/keys/view_only_wallet_data.dart';
import '../../../utilities/util.dart';
import '../../../widgets/custom_buttons/simple_copy_button.dart';
import '../../../widgets/detail_item.dart';
import '../../../widgets/icon_buttons.dart';

class ViewOnlyWalletDataWidget extends StatelessWidget {
  const ViewOnlyWalletDataWidget({super.key, required this.data});

  final ViewOnlyWalletData data;

  @override
  Widget build(BuildContext context) {
    return switch (data) {
      final AddressViewOnlyWalletData e => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailItem(
            title: l10n.commonAddress,
            detail: e.address,
            button: Util.isDesktop
                ? IconCopyButton(data: e.address)
                : SimpleCopyButton(data: e.address),
          ),
        ],
      ),
      final ExtendedKeysViewOnlyWalletData e => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...e.xPubs.map(
            (xPub) => DetailItem(
              title: xPub.path,
              detail: xPub.encoded,
              button: Util.isDesktop
                  ? IconCopyButton(data: xPub.encoded)
                  : SimpleCopyButton(data: xPub.encoded),
            ),
          ),
        ],
      ),
      final SaplingViewingKeyViewOnlyWalletData e => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailItem(
            title: l10n.walletShieldViewingKey,
            detail: e.viewingKey,
            button: Util.isDesktop
                ? IconCopyButton(data: e.viewingKey)
                : SimpleCopyButton(data: e.viewingKey),
          ),
        ],
      ),
    };
  }
}
