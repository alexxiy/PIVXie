import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
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
          message: e is FormatException ? e.message : l10n.mnInvalidServer,
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
          title: l10n.mnIsRunning,
          message: l10n.mnRestartWarning,
          leftButton: SecondaryButton(
            label: l10n.commonCancel,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          rightButton: PrimaryButton(
            label: l10n.mnRestart,
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
      message: l10n.mnStarting,
      onException: (e) => error = e,
    );
    if (!mounted) return;
    if (answer == null) {
      await showFloatingFlushBar(
        type: FlushBarType.warning,
        message:
            error?.toString().replaceFirst("Exception: ", "") ??
            l10n.mnStartFailed,
        context: context,
        duration: const Duration(seconds: 5),
      );
      return;
    }
    _serviceController.text = service;
    setState(() => _statusRefresh++);
    await showFloatingFlushBar(
      type: FlushBarType.success,
      message: l10n.mnStartSent,
      context: context,
      duration: const Duration(seconds: 5),
    );
  }

  /// Copies [text], which holds the masternode key.
  Future<void> _copy(String text, [String? what]) async {
    await const ClipboardWrapper().setSecret(text);
    if (mounted) {
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.info,
          message: what ?? l10n.commonCopiedToClipboard,
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
      title: l10n.mnShowKey,
      reason: l10n.mnShowKeyReason,
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
              text: _showKey ? l10n.commonHide : l10n.commonShow,
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
            CustomTextButton(text: l10n.commonShow, onTap: _revealKey),
        ],
      ),
    );
  }

  Future<void> _showHostingDetails(PivxMasternode mn, String key) async {
    final colors = Theme.of(context).extension<StackColors>()!;
    final all =
        "${l10n.mnCollateralTx}: ${mn.txid}\n"
        "${l10n.mnOutputIndex}: ${mn.vout}\n"
        "${l10n.mnPrivateKey}: $key";
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
              Text(l10n.mnHostTitle, style: STextStyles.pageTitleH2(context)),
              const SizedBox(height: 8),
              Text(l10n.mnHostText, style: STextStyles.itemSubtitle(context)),
              const SizedBox(height: 16),
              _row(l10n.mnCollateralTx, mn.txid),
              const SizedBox(height: 8),
              _row(l10n.mnOutputIndex, "${mn.vout}"),
              const SizedBox(height: 8),
              _row(l10n.mnPrivateKey, key),
              const SizedBox(height: 16),
              SecondaryButton(
                label: l10n.mnCopyAll,
                onPressed: () => _copy(all, l10n.mnHostingCopied),
              ),
              const SizedBox(height: 8),
              PrimaryButton(
                label: l10n.mnOpenMasternodeSpace,
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
        title: l10n.mnRemoveTitle,
        message: l10n.mnRemoveText,
        leftButton: SecondaryButton(
          label: l10n.commonCancel,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        rightButton: PrimaryButton(
          label: l10n.commonRemove,
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
            mn == null || mn.label.isEmpty ? l10n.mnMasternode : mn.label,
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
                          Text(
                            l10n.mnStatus,
                            style: STextStyles.w600_14(context),
                          ),
                          const Spacer(),
                          PivxMasternodeStatusTag(
                            key: ValueKey(_statusRefresh),
                            wallet: wallet,
                            masternode: mn,
                          ),
                          const SizedBox(width: 8),
                          CustomTextButton(
                            text: l10n.commonRefresh,
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
                            l10n.mnStart,
                            style: STextStyles.w600_14(context),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.mnStartText,
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
                                            l10n.mnServerIpExample,
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
                            label: l10n.mnStart,
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
                    _row(l10n.mnCollateralAddress, mn.address),
                    const SizedBox(height: 8),
                    _row(l10n.mnCollateralTx, mn.txid),
                    const SizedBox(height: 8),
                    _row(l10n.mnOutputIndex, "${mn.vout}"),
                    const SizedBox(height: 8),
                    _row(l10n.mnPrivateKey, key, secret: true),
                    const SizedBox(height: 24),
                    Text(l10n.mnEasiest, style: STextStyles.w600_14(context)),
                    const SizedBox(height: 8),
                    Text(
                      l10n.mnEasiestText,
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 12),
                    PrimaryButton(
                      label: l10n.mnShowWhatNeeded,
                      onPressed: () async {
                        if (await _revealKey() && mounted) {
                          await _showHostingDetails(mn, key);
                        }
                      },
                    ),
                    const SizedBox(height: 24),
                    Text(l10n.mnOwnVps, style: STextStyles.w600_14(context)),
                    const SizedBox(height: 8),
                    Text(
                      mn.service == null
                          ? l10n.mnOwnVpsTextReplaceIp(wallet.masternodePort)
                          : l10n.mnOwnVpsText(wallet.masternodePort),
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 8),
                    _codeBlock((k) => wallet.masternodePivxConf(mn, k), key),
                    const SizedBox(height: 12),
                    Text(
                      l10n.mnConfLine,
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 8),
                    _codeBlock((k) => wallet.masternodeConfLine(mn, k), key),
                    const SizedBox(height: 24),
                    SecondaryButton(
                      label: l10n.mnRemove,
                      onPressed: () => _remove(mn),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
