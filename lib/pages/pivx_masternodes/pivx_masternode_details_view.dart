import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../notifications/show_flush_bar.dart';
import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_dialog.dart';
import '../wallet_view/transaction_views/tx_v2/transaction_v2_details_view.dart'
    show IconCopyButton;
import 'pivx_masternodes_view.dart';

const _kMasternodeSpaceUrl = "https://masternode.space";

/// One masternode: collateral, key, and how to get it running (hosted on
/// masternode.space or on your own VPS).
class PivxMasternodeDetailsView extends ConsumerStatefulWidget {
  const PivxMasternodeDetailsView({
    super.key,
    required this.walletId,
    required this.masternodeId,
  });

  static const routeName = "/pivxMasternodeDetails";

  final String walletId;
  final String masternodeId;

  @override
  ConsumerState<PivxMasternodeDetailsView> createState() =>
      _PivxMasternodeDetailsViewState();
}

class _PivxMasternodeDetailsViewState
    extends ConsumerState<PivxMasternodeDetailsView> {
  String? _key;
  bool _showKey = false;
  int _statusRefresh = 0;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  PivxMasternode? get _masternode {
    final list = _wallet.masternodes.where((e) => e.id == widget.masternodeId);
    return list.isEmpty ? null : list.first;
  }

  @override
  void initState() {
    final mn = _masternode;
    if (mn != null) {
      unawaited(
        _wallet.masternodeKey(mn).then((k) {
          if (mounted) setState(() => _key = k);
        }),
      );
    }
    super.initState();
  }

  Future<void> _copy(String text, [String what = "Copied to clipboard"]) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.info,
          message: what,
          context: context,
        ),
      );
    }
  }

  Widget _row(String label, String value, {bool secret = false}) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: STextStyles.w500_12(
                    context,
                  ).copyWith(color: colors.textSubtitle1),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  secret && !_showKey ? "••••••••••••••••••••" : value,
                  style: STextStyles.w600_14(context),
                ),
              ],
            ),
          ),
          if (secret)
            CustomTextButton(
              text: _showKey ? "Hide" : "Show",
              onTap: () => setState(() => _showKey = !_showKey),
            ),
          const SizedBox(width: 8),
          IconCopyButton(data: value),
        ],
      ),
    );
  }

  Widget _codeBlock(String code) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              code,
              style: STextStyles.w500_12(context).copyWith(
                fontFamily: "monospace",
                color: colors.textDark,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconCopyButton(data: code),
        ],
      ),
    );
  }

  Future<void> _showHostingDetails(PivxMasternode mn, String key) async {
    final colors = Theme.of(context).extension<StackColors>()!;
    final all =
        "Collateral transaction: ${mn.txid}\n"
        "Output index: ${mn.vout}\n"
        "Masternode private key: $key";
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: colors.popupBG,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "Host on masternode.space",
              style: STextStyles.pageTitleH2(context),
            ),
            const SizedBox(height: 8),
            Text(
              "Give masternode.space these three values when you order "
              "hosting for this masternode. Your collateral never leaves "
              "this wallet.",
              style: STextStyles.itemSubtitle(context),
            ),
            const SizedBox(height: 16),
            _row("Collateral transaction", mn.txid),
            const SizedBox(height: 8),
            _row("Output index", "${mn.vout}"),
            const SizedBox(height: 8),
            _row("Masternode private key", key),
            const SizedBox(height: 16),
            SecondaryButton(
              label: "Copy all",
              onPressed: () => _copy(all, "Hosting details copied"),
            ),
            const SizedBox(height: 8),
            PrimaryButton(
              label: "Open masternode.space",
              onPressed: () => launchUrl(
                Uri.parse(_kMasternodeSpaceUrl),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(PivxMasternode mn) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        title: "Remove masternode?",
        message:
            "PIVXie forgets this masternode and unfreezes its collateral, so "
            "it can be spent. If the masternode is running, spending the "
            "collateral stops it.",
        leftButton: SecondaryButton(
          label: "Cancel",
          onPressed: () => Navigator.of(context).pop(false),
        ),
        rightButton: PrimaryButton(
          label: "Remove",
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ),
    );
    if (confirmed != true) return;
    await _wallet.removeMasternode(mn);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final mn = _masternode;
    final key = _key ?? "";

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            mn == null || mn.label.isEmpty ? "Masternode" : mn.label,
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: mn == null
            ? const SizedBox.shrink()
            : SafeArea(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    RoundedWhiteContainer(
                      child: Row(
                        children: [
                          Text("Status", style: STextStyles.w600_14(context)),
                          const Spacer(),
                          PivxMasternodeStatusTag(
                            key: ValueKey(_statusRefresh),
                            wallet: wallet,
                            masternode: mn,
                          ),
                          const SizedBox(width: 8),
                          CustomTextButton(
                            text: "Refresh",
                            onTap: () => setState(() => _statusRefresh++),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    _row("Collateral address", mn.address),
                    const SizedBox(height: 8),
                    _row("Collateral transaction", mn.txid),
                    const SizedBox(height: 8),
                    _row("Output index", "${mn.vout}"),
                    const SizedBox(height: 8),
                    _row("Masternode private key", key, secret: true),
                    const SizedBox(height: 24),
                    Text(
                      "Easiest: host it on masternode.space",
                      style: STextStyles.w600_14(context),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "masternode.space runs the server for you: no VPS to "
                      "rent, set up or keep online. You only give them the "
                      "collateral transaction, its output index and the "
                      "masternode private key.",
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 12),
                    PrimaryButton(
                      label: "Show what masternode.space needs",
                      onPressed: () => _showHostingDetails(mn, key),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      "Or run it on your own VPS",
                      style: STextStyles.w600_14(context),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Install PIVX Core on the server, add these lines to "
                      "its pivx.conf (replace YOUR_VPS_IP with the server's "
                      "public IP; port ${wallet.masternodePort} must be "
                      "reachable) and restart pivxd.",
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 8),
                    _codeBlock(wallet.masternodePivxConf(mn, key)),
                    const SizedBox(height: 12),
                    Text(
                      "masternode.conf line, for a PIVX Core controller "
                      "wallet:",
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 8),
                    _codeBlock(wallet.masternodeConfLine(mn, key)),
                    const SizedBox(height: 24),
                    SecondaryButton(
                      label: "Remove masternode",
                      onPressed: () => _remove(mn),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
