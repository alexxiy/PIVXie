import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/show_flush_bar.dart';
import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/logger.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/secret_screen.dart';
import '../../widgets/stack_text_field.dart';

/// Add the masternodes of a PIVX Core masternode.conf whose collateral is
/// in this wallet. Pops with how many were added.
class PivxImportMasternodeConfView extends ConsumerStatefulWidget {
  const PivxImportMasternodeConfView({super.key, required this.walletId});

  static const routeName = "/pivxImportMasternodeConf";

  final String walletId;

  @override
  ConsumerState<PivxImportMasternodeConfView> createState() =>
      _PivxImportMasternodeConfViewState();
}

class _PivxImportMasternodeConfViewState
    extends ConsumerState<PivxImportMasternodeConfView> {
  /// Larger than any masternode.conf (a line is ~170 bytes).
  static const _kMaxFileBytes = 2 * 1024 * 1024;

  final _controller = TextEditingController();
  final _focus = FocusNode();

  List<PivxMasternodeConfImport>? _plan;
  Timer? _debounce;

  /// Plans started; an older one finishing late is dropped.
  int _planning = 0;
  bool _importing = false;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _replan);
  }

  Future<void> _replan() async {
    final text = _controller.text;
    final n = ++_planning;
    final plan = text.trim().isEmpty
        ? null
        : await _wallet.planMasternodeConfImport(text);
    if (mounted && n == _planning) setState(() => _plan = plan);
  }

  Future<void> _openFile() async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: "Open masternode.conf",
        type: FileType.any,
      );
      if (file == null) return;
      final size = await file.length();
      if (size != null && size > _kMaxFileBytes) {
        throw const FormatException(
          "Not a masternode.conf: the file is too big",
        );
      }
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      _controller.text = text;
      _debounce?.cancel();
      await _replan();
    } catch (e, s) {
      Logging.instance.w(
        "masternode.conf open failed",
        error: e,
        stackTrace: s,
      );
      if (mounted) {
        unawaited(
          showFloatingFlushBar(
            type: FlushBarType.warning,
            message: e is FormatException
                ? e.message
                : "Couldn't read that file",
            context: context,
          ),
        );
      }
    }
  }

  Future<void> _import() async {
    final plan = _plan;
    if (plan == null) return;
    setState(() => _importing = true);
    try {
      final added = await _wallet.importMasternodes(plan);
      if (mounted) Navigator.of(context).pop(added);
    } catch (e, s) {
      Logging.instance.e(
        "masternode.conf import failed",
        error: e,
        stackTrace: s,
      );
      if (mounted) {
        setState(() => _importing = false);
        unawaited(
          showFloatingFlushBar(
            type: FlushBarType.warning,
            message: "Couldn't add the masternodes: $e",
            context: context,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) =>
      SecretScreen(child: Builder(builder: _buildScreen));

  Widget _buildScreen(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final plan = _plan;
    final toAdd = plan?.where((p) => p.imported).length ?? 0;

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            "Import masternode.conf",
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  itemCount: 1 + (plan?.length ?? 0),
                  itemBuilder: (context, i) => i == 0
                      ? _header(context, plan, toAdd)
                      : Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _LineCard(item: plan![i - 1]),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: PrimaryButton(
                  label: _importing
                      ? "Adding…"
                      : switch (toAdd) {
                          0 => "Add masternodes",
                          1 => "Add 1 masternode",
                          _ => "Add $toAdd masternodes",
                        },
                  enabled: toAdd > 0 && !_importing,
                  onPressed: _import,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    List<PivxMasternodeConfImport>? plan,
    int toAdd,
  ) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final skipped = (plan?.length ?? 0) - toAdd;
    // No collateral is the wallet's: most likely the wrong wallet, or one
    // still syncing.
    final noneHere =
        plan != null &&
        plan.any((p) => p.collateralInWallet == false) &&
        !plan.any((p) => p.collateralInWallet == true);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          "Add the masternodes from your PIVX Core masternode.conf. Only "
          "masternodes whose collateral is in this wallet are added, and a "
          "line whose IP or collateral is already used is skipped. Your "
          "masternodes here stay as they are, and nothing is sent or "
          "started.\n\n"
          "Each line of the file reads: alias IP:port masternodeprivkey "
          "collateral_txid collateral_index.",
          style: STextStyles.itemSubtitle(context),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("masternode.conf", style: STextStyles.smallMed12(context)),
            CustomTextButton(text: "Open file", onTap: _openFile),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 4,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            style: STextStyles.w500_12(context)
                .copyWith(fontFamily: "monospace", color: colors.textDark),
            onChanged: (_) => _changed(),
            decoration: standardInputDecoration(
              "Paste masternode.conf here",
              _focus,
              context,
            ),
          ),
        ),
        if (plan != null) ...[
          const SizedBox(height: 16),
          Text(
            plan.isEmpty
                ? "No masternode lines found"
                : [
                    toAdd == 1 ? "1 to add" : "$toAdd to add",
                    if (skipped > 0) "$skipped skipped",
                  ].join(" · "),
            style: STextStyles.w600_14(context),
          ),
          if (noneHere) ...[
            const SizedBox(height: 8),
            RoundedWhiteContainer(
              child: Text(
                "None of these collaterals is in this wallet. Open the "
                "wallet that holds them, or wait until this one has "
                "finished syncing.",
                style: STextStyles.itemSubtitle(context),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// One masternode.conf line: what it is and whether it is added.
class _LineCard extends StatelessWidget {
  const _LineCard({required this.item});

  final PivxMasternodeConfImport item;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final color = item.imported
        ? colors.accentColorGreen
        : colors.textSubtitle1;
    final note =
        item.skipped ??
        (item.renamed ? "Will be added as ${item.masternode!.label}" : null);
    final txid = item.collateral.split(":").first;

    return RoundedWhiteContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.alias,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.w600_14(context),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  item.imported ? "To add" : "Skipped",
                  style: STextStyles.w600_12(context).copyWith(color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              "Line ${item.line}",
              if (item.service.isNotEmpty) item.service,
              if (txid.length > 8)
                "${txid.substring(0, 8)}…:${item.collateral.split(":").last}",
            ].join(" · "),
            overflow: TextOverflow.ellipsis,
            style: STextStyles.w500_12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(
              note,
              style: STextStyles.w500_12(context)
                  .copyWith(color: colors.textDark),
            ),
          ],
        ],
      ),
    );
  }
}
