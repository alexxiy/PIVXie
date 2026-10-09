import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/rounded_white_container.dart';
import 'pivx_create_masternode_view.dart';
import 'pivx_masternode_details_view.dart';

/// The wallet's PIVX masternodes, from the wallet's "More" menu.
class PivxMasternodesView extends ConsumerStatefulWidget {
  const PivxMasternodesView({super.key, required this.walletId});

  static const routeName = "/pivxMasternodes";

  final String walletId;

  @override
  ConsumerState<PivxMasternodesView> createState() =>
      _PivxMasternodesViewState();
}

class _PivxMasternodesViewState extends ConsumerState<PivxMasternodesView> {
  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  Future<void> _open(String route, Object arguments) async {
    await Navigator.of(context).pushNamed(route, arguments: arguments);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final masternodes = wallet.masternodes;

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text("Masternodes", style: STextStyles.navBarTitle(context)),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: masternodes.isEmpty
                      ? ListView(
                          children: [
                            RoundedWhiteContainer(
                              child: Text(
                                "A masternode locks a collateral of "
                                "${wallet.masternodeCollateral.decimal} "
                                "${wallet.cryptoCurrency.ticker} in this "
                                "wallet and earns masternode rewards while a "
                                "server runs it. The collateral stays yours "
                                "and is frozen so it can't be spent by "
                                "accident.",
                                style: STextStyles.itemSubtitle(context),
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          itemCount: masternodes.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, i) {
                            final mn = masternodes[i];
                            return GestureDetector(
                              onTap: () => _open(
                                PivxMasternodeDetailsView.routeName,
                                (walletId: widget.walletId, id: mn.id),
                              ),
                              child: RoundedWhiteContainer(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            mn.label.isEmpty
                                                ? "Masternode"
                                                : mn.label,
                                            style: STextStyles.w600_14(
                                              context,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            mn.address,
                                            style: STextStyles.w500_12(
                                              context,
                                            ).copyWith(
                                              color: colors.textSubtitle1,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            "${mn.txid.substring(0, 12)}…"
                                            ":${mn.vout}",
                                            style: STextStyles.w500_12(
                                              context,
                                            ).copyWith(
                                              color: colors.textSubtitle1,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    PivxMasternodeStatusTag(
                                      wallet: wallet,
                                      masternode: mn,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: "Create masternode",
                  onPressed: () => _open(
                    PivxCreateMasternodeView.routeName,
                    widget.walletId,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Masternode status from the network, as a coloured tag.
class PivxMasternodeStatusTag extends StatelessWidget {
  const PivxMasternodeStatusTag({
    super.key,
    required this.wallet,
    required this.masternode,
  });

  final PivxWallet wallet;
  final PivxMasternode masternode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return FutureBuilder<String>(
      future: wallet.masternodeStatus(masternode),
      builder: (context, snapshot) {
        final status = snapshot.data ?? "…";
        final color = switch (status) {
          "ENABLED" => colors.accentColorGreen,
          "PRE_ENABLED" => colors.accentColorYellow,
          "…" || "UNKNOWN" => colors.textSubtitle1,
          _ => colors.accentColorRed,
        };
        return Text(
          status == "MISSING" ? "NOT STARTED" : status.replaceAll("_", " "),
          style: STextStyles.w600_14(context).copyWith(color: color),
        );
      },
    );
  }
}
