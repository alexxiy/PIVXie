import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/pivx_defi/pivx_defi_api.dart';
import '../../services/pivx_defi/pivx_defi_models.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/logger.dart';
import '../../utilities/text_styles.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/background.dart';
import '../../widgets/rounded_white_container.dart';
import 'pivx_defi_common.dart';

/// The wPIVX supply beside the PIVX the bridge's vault holds, and how to
/// check the vault with its viewing key (the web app's Reserves page).
class PivxDefiReservesView extends ConsumerStatefulWidget {
  const PivxDefiReservesView({super.key, required this.walletId});

  static const routeName = kPivxDefiReservesRoute;

  final String walletId;

  @override
  ConsumerState<PivxDefiReservesView> createState() =>
      _PivxDefiReservesViewState();
}

class _PivxDefiReservesViewState extends ConsumerState<PivxDefiReservesView> {
  late final PivxDefiApi _api;
  PivxDefiReserves? _reserves;
  var _failed = false;
  PivxDefiInfo? _info;

  @override
  void initState() {
    super.initState();
    final coin = ref.read(pWallets).getWallet(widget.walletId).cryptoCurrency;
    _api = PivxDefiApi.forCoin(coin)!;
    _info = pivxDefiLastInfo;
    unawaited(_load());
    if (_info == null) {
      unawaited(
        loadPivxDefiInfo(_api).then(
          (info) {
            if (mounted) setState(() => _info = info);
          },
          onError: (Object e) {
            Logging.instance.w("DeFi Bridge info failed: $e");
          },
        ),
      );
    }
  }

  Future<void> _load() async {
    try {
      final reserves = await _api.reserves();
      if (mounted) setState(() => _reserves = reserves);
    } catch (e, s) {
      Logging.instance.w(
        "DeFi Bridge reserves failed",
        error: e,
        stackTrace: s,
      );
      if (mounted) setState(() => _failed = true);
    }
  }

  /// "-1.5" for an amount below zero.
  String _signed(int sat) =>
      sat < 0 ? "-${showPivxDefiAmount(-sat)}" : showPivxDefiAmount(sat);

  Widget _tile(StackColors colors, String label, int amount, String symbol) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colors.textFieldDefaultBG,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: STextStyles.w600_12(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
              const SizedBox(height: 4),
              Text(
                showPivxDefiAmount(amount),
                style: STextStyles.pageTitleH2(context),
              ),
              Text(
                symbol,
                style: STextStyles.w500_12(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
            ],
          ),
        ),
      );

  Widget _code(StackColors colors, String line) => Material(
    color: colors.textFieldDefaultBG,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => pivxDefiCopy(context, line, l10n.defiReservesVerify),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Text(
          line,
          textDirection: TextDirection.ltr,
          style: STextStyles.w500_12(context)
              .copyWith(color: colors.textDark, fontFamily: "monospace"),
        ),
      ),
    ),
  );

  List<Widget> _body(StackColors colors, PivxDefiReserves r) {
    final (status, text) = switch (r.status) {
      "match" => (l10n.defiReservesMatch, l10n.defiReservesMatchText),
      "in_process" => (
        l10n.defiReservesInProcess,
        l10n.defiReservesInProcessText(_signed(r.difference)),
      ),
      "mismatch" => (l10n.defiReservesMismatch, l10n.defiReservesMismatchText),
      _ => (l10n.defiReservesUnavailable, l10n.defiReservesUnavailableText),
    };
    final statusColor = switch (r.status) {
      "match" => pivxDefiGreen(colors),
      "mismatch" => colors.textError,
      _ => pivxDefiColor(PivxDefiDirection.unwrap, colors),
    };
    String partLabel(String key) => switch (key) {
      "moving_to_vault" => l10n.defiReservesMovingToVault,
      "burns_in_flight" => l10n.defiReservesBurnsInFlight,
      "burns_held" => l10n.defiReservesBurnsHeld,
      "surplus" => l10n.defiReservesSurplus,
      "unbacked" => l10n.defiReservesUnbacked,
      _ =>
        r.status == "mismatch"
            ? l10n.defiReservesUnexplained
            : l10n.defiReservesUnconfirmed,
    };
    final parts = [
      for (final key in PivxDefiReserves.parts)
        if ((r.amounts[key] ?? 0) != 0) key,
    ];
    final tokenUrl = _info?.evmTokenUrl(r.token);
    final key = r.viewingKey;
    final updated = r.updated;
    final heading = STextStyles.w600_14(context);
    final subtle = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    return [
      Row(
        children: [
          _tile(colors, l10n.defiReservesSupply, r.supply, "wPIVX"),
          const SizedBox(width: 10),
          _tile(colors, l10n.defiReservesBalance, r.balance, "PIVX"),
        ],
      ),
      const SizedBox(height: 16),
      Text(status, style: heading.copyWith(color: statusColor)),
      const SizedBox(height: 4),
      Text(text, style: subtle),
      if (parts.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(l10n.defiReservesParts, style: heading),
        const SizedBox(height: 4),
        for (final p in parts)
          PivxDefiRow(
            label: partLabel(p),
            value: "${_signed(r.amounts[p]!)} PIVX",
          ),
      ],
      const SizedBox(height: 16),
      Text(l10n.defiReservesVerify, style: heading),
      const SizedBox(height: 4),
      PivxDefiRow(
        label: l10n.defiReservesToken,
        value: r.token,
        mono: true,
        onOpen: tokenUrl == null ? null : () => pivxDefiOpen(tokenUrl),
        onCopy: () => pivxDefiCopy(context, r.token, l10n.defiReservesToken),
      ),
      PivxDefiRow(
        label: l10n.defiReservesVaultWallet,
        value: r.vaultWallet,
        mono: true,
        onCopy: () =>
            pivxDefiCopy(context, r.vaultWallet, l10n.defiReservesVaultWallet),
      ),
      if (key != null)
        PivxDefiRow(
          label: l10n.defiReservesViewingKey,
          value: key,
          mono: true,
          onCopy: () => pivxDefiCopy(context, key, l10n.defiReservesViewingKey),
        ),
      const SizedBox(height: 12),
      if (key != null) ...[
        Text(l10n.defiReservesVerifyText, style: subtle),
        const SizedBox(height: 8),
        _code(
          colors,
          "importsaplingviewingkey $key '\"whenkeyisnew\"' ${r.startBlock ?? 0}",
        ),
        const SizedBox(height: 8),
        _code(colors, "getshieldbalance ${r.vaultWallet} 1 true"),
      ] else
        Text(l10n.defiReservesNoKey, style: subtle),
      if (updated != null) ...[
        const SizedBox(height: 12),
        Text(
          "${l10n.defiReservesUpdated}: ${pivxDefiDate(updated)}",
          style: subtle,
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final r = _reserves;
    return Background(
      child: AppScaffold(
        maxBodyWidth: ScreenFit.columnWidth,
        backgroundColor: colors.background,
        appBar: PivxDefiAppBar(
          walletId: widget.walletId,
          config: _api.config,
          title: l10n.defiReserves,
          webPath: "reserves",
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  l10n.defiReservesIntro,
                  style: STextStyles.w500_14(context),
                ),
                const SizedBox(height: 16),
                if (r != null)
                  RoundedWhiteContainer(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _body(colors, r),
                    ),
                  )
                else if (_failed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Text(
                      l10n.defiReservesFailed,
                      textAlign: TextAlign.center,
                      style: STextStyles.itemSubtitle(context),
                    ),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
