import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../notifications/show_flush_bar.dart';
import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/clipboard_interface.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/icon_buttons.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/secret_screen.dart';
import '../../widgets/stack_dialog.dart';
import '../../widgets/stack_text_field.dart';
import '../pinpad_views/authenticate_user.dart';
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
  final _serviceController = TextEditingController();
  final _serviceFocus = FocusNode();

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  PivxMasternode? get _masternode {
    final list = _wallet.masternodes.where((e) => e.id == widget.masternodeId);
    return list.isEmpty ? null : list.first;
  }

  @override
  void initState() {
    final mn = _masternode;
    _serviceController.text = mn?.service ?? "";
    _wallet.loadMasternodeNetwork().then((_) {
      if (mounted) setState(() {});
    });
    if (mn != null) {
      unawaited(
        _wallet.masternodeKey(mn).then((k) {
          if (mounted) setState(() => _key = k);
        }),
      );
    }
    super.initState();
  }

  @override
  void dispose() {
    _serviceController.dispose();
    _serviceFocus.dispose();
    super.dispose();
  }

  Future<void> _start(PivxMasternode mn) async {
    final wallet = _wallet;
    final String service;
    try {
      service = wallet.normalizeMasternodeService(_serviceController.text);
    } catch (e) {
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.warning,
          message: e is FormatException ? e.message : "Invalid server address",
          context: context,
        ),
      );
      return;
    }
    _serviceFocus.unfocus();

    // Restarting a running masternode sends it to the back of the
    // payment queue.
    final status = await wallet.masternodeStatus(mn);
    if (!mounted) return;
    if (status == "ENABLED" || status == "PRE_ENABLED") {
      final restart = await showDialog<bool>(
        context: context,
        builder: (context) => StackDialog(
          title: "Masternode is running",
          message:
              "Restarting puts it back at the end of the payment queue: "
              "no rewards for days. Only restart it if it's really down.",
          leftButton: SecondaryButton(
            label: "Cancel",
            onPressed: () => Navigator.of(context).pop(false),
          ),
          rightButton: PrimaryButton(
            label: "Restart",
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ),
      );
      if (restart != true || !mounted) return;
    }

    Exception? error;
    final answer = await showLoading<String>(
      whileFuture: wallet.startMasternode(mn, service: service),
      context: context,
      message: "Starting masternode",
      onException: (e) => error = e,
    );
    if (!mounted) return;
    if (answer == null) {
      await showFloatingFlushBar(
        type: FlushBarType.warning,
        message:
            error?.toString().replaceFirst("Exception: ", "") ??
            "Could not start the masternode",
        context: context,
        duration: const Duration(seconds: 5),
      );
      return;
    }
    _serviceController.text = service;
    setState(() => _statusRefresh++);
    await showFloatingFlushBar(
      type: FlushBarType.success,
      message:
          "Start message sent. The masternode shows as enabled after "
          "its first ping, usually within a few minutes.",
      context: context,
      duration: const Duration(seconds: 5),
    );
  }

  /// Copies [text], which holds the masternode key.
  Future<void> _copy(String text, [String what = "Copied to clipboard"]) async {
    await const ClipboardWrapper().setSecret(text);
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

  /// Shows the masternode key once the user proved it's them (PIN or
  /// password): it can vote as the masternode and run it elsewhere.
  Future<bool> _revealKey() async {
    if (_showKey) return true;
    final ok = await authenticateUser(
      context,
      coin: _wallet.cryptoCurrency,
      title: "Show masternode key",
      reason: "Unlock to show the masternode private key",
    );
    if (ok && mounted) setState(() => _showKey = true);
    return ok;
  }

  static const _hiddenKey = "••••••••••••••••••••";

  /// Shorter in config lines, which then fit a phone's width.
  static const _hiddenKeyInCode = "••••••••••••";

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
                  style: STextStyles.w500_12(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  secret && !_showKey ? _hiddenKey : value,
                  style: STextStyles.w600_14(context),
                ),
              ],
            ),
          ),
          if (secret)
            CustomTextButton(
              text: _showKey ? "Hide" : "Show",
              onTap: _showKey
                  ? () => setState(() => _showKey = false)
                  : _revealKey,
            ),
          if (!secret || _showKey) ...[
            const SizedBox(width: 8),
            IconCopyButton(data: value, secret: secret),
          ],
        ],
      ),
    );
  }

  /// [code] holds the masternode key: hidden, and not copied, until
  /// [_revealKey].
  Widget _codeBlock(String Function(String key) code, String key) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              code(_showKey ? key : _hiddenKeyInCode),
              style: STextStyles.w500_12(context)
                  .copyWith(fontFamily: "monospace", color: colors.textDark),
            ),
          ),
          const SizedBox(width: 8),
          if (_showKey)
            IconCopyButton(data: code(key), secret: true)
          else
            CustomTextButton(text: "Show", onTap: _revealKey),
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
        child: SafeArea(
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
  Widget build(BuildContext context) =>
      SecretScreen(child: Builder(builder: _buildScreen));

  Widget _buildScreen(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final mn = _masternode;
    final key = _key ?? "";
    final serviceError = _serviceController.text.trim().isEmpty
        ? null
        : wallet.masternodeServiceError(_serviceController.text);

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PageAppBar(
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
                    RoundedWhiteContainer(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            "Start masternode",
                            style: STextStyles.w600_14(context),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "Once the server runs PIVX Core with this "
                            "masternode's private key, enter its IP address "
                            "and start it. Start it again if it shows as "
                            "missing or expired.",
                            style: STextStyles.itemSubtitle(context),
                          ),
                          const SizedBox(height: 10),
                          Builder(
                            builder: (context) {
                              final colors = Theme.of(context)
                                  .extension<StackColors>()!;
                              final border = serviceError == null
                                  ? null
                                  : OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(
                                        color: colors.textError,
                                        width: 1.5,
                                      ),
                                    );
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: TextField(
                                      controller: _serviceController,
                                      focusNode: _serviceFocus,
                                      autocorrect: false,
                                      enableSuggestions: false,
                                      keyboardType: TextInputType.url,
                                      style: STextStyles.field(context),
                                      onChanged: (_) => setState(() {}),
                                      decoration:
                                          standardInputDecoration(
                                            "Server IP, e.g. 203.0.113.5",
                                            _serviceFocus,
                                            context,
                                          ).copyWith(
                                            enabledBorder: border,
                                            focusedBorder: border,
                                          ),
                                    ),
                                  ),
                                  if (serviceError != null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        left: 12,
                                        top: 4,
                                      ),
                                      child: Text(
                                        serviceError,
                                        style: STextStyles.label(context)
                                            .copyWith(color: colors.textError),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 10),
                          PrimaryButton(
                            label: "Start masternode",
                            enabled:
                                !wallet.isViewOnly &&
                                _serviceController.text.trim().isNotEmpty &&
                                serviceError == null,
                            onPressed: () => _start(mn),
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
                      onPressed: () async {
                        if (await _revealKey() && mounted) {
                          await _showHostingDetails(mn, key);
                        }
                      },
                    ),
                    const SizedBox(height: 24),
                    Text(
                      "Or run it on your own VPS",
                      style: STextStyles.w600_14(context),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Install PIVX Core on the server, add these lines to "
                      "its pivx.conf${mn.service == null ? " (replace "
                                "YOUR_VPS_IP with the server's public IP)" : ""}, "
                      "make sure port ${wallet.masternodePort} is reachable "
                      "and restart pivxd. Then start the masternode above.",
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 8),
                    _codeBlock((k) => wallet.masternodePivxConf(mn, k), key),
                    const SizedBox(height: 12),
                    Text(
                      "masternode.conf line, for a PIVX Core controller "
                      "wallet:",
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 8),
                    _codeBlock((k) => wallet.masternodeConfLine(mn, k), key),
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
