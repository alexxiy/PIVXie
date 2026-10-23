import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/pivx_name/pivx_name.dart';
import '../../services/pivx_name/pivx_names_protocol.dart';
import '../../services/pivx_name/pivx_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_dialog.dart';
import 'pivx_names_common.dart';
import 'pivx_names_status_view.dart';

/// The user's payments to PIVX.name (and where each stands) and their
/// withdrawals. A payment in progress opens its status screen.
class PivxNamesTransactionsView extends ConsumerStatefulWidget {
  const PivxNamesTransactionsView({super.key, required this.walletId});

  static const routeName = kPivxNamesTransactionsRoute;

  final String walletId;

  @override
  ConsumerState<PivxNamesTransactionsView> createState() =>
      _PivxNamesTransactionsViewState();
}

class _PivxNamesTransactionsViewState
    extends ConsumerState<PivxNamesTransactionsView> {
  bool _refunds = false;
  int _page = 1;
  bool _loading = true;
  String? _error;
  int _request = 0;
  int _paymentConfirmations = kPivxNamesPaymentConfirmations;
  int _refundConfirmations = kPivxNamesRefundConfirmations;

  PivxNamesPage<PivxNamesIncoming>? _incoming;
  PivxNamesPage<PivxNamesRefund>? _refundList;

  /// Sent from this wallet and not listed by PIVX.name yet.
  List<PivxNamesSent> _sent = const [];

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  PivxNamesRegistrar get _registrar =>
      PivxNamesRegistrar.forCoin(_wallet.cryptoCurrency)!;

  @override
  void initState() {
    super.initState();
    pivxNamesChanges.addListener(_changed);
    _sent = _wallet.namesSent;
    unawaited(_load());
    unawaited(
      _registrar.paymentInfo().then((info) {
        if (!mounted) return;
        setState(() {
          _paymentConfirmations = info.paymentConfirmations;
          _refundConfirmations = info.refundConfirmations;
        });
      }, onError: (_) {}),
    );
  }

  @override
  void dispose() {
    pivxNamesChanges.removeListener(_changed);
    super.dispose();
  }

  void _changed() => unawaited(_load());

  Future<void> _load() async {
    final request = ++_request;
    final refunds = _refunds;
    final page = _page;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final wallet = _wallet;
      final identity = await wallet.namesIdentity();
      final nonce = pivxNamesNonce();
      final signature = await identity.sign(
        pivxNamesHistoryMessage(
          marker: _registrar.service.marker,
          type: refunds ? "ref" : "in",
          pubkey: identity.publicKey,
          page: page,
          count: kPivxNamesHistoryPageSize,
          nonce: nonce,
        ),
      );
      if (refunds) {
        final list = await _registrar.refunds(
          pubkey: identity.publicKey,
          page: page,
          nonce: nonce,
          signature: signature,
        );
        if (!mounted || request != _request) return;
        setState(() => _refundList = list);
      } else {
        final list = await _registrar.incoming(
          pubkey: identity.publicKey,
          page: page,
          nonce: nonce,
          signature: signature,
        );
        if (!mounted || request != _request) return;
        // Listed now: no need to keep them.
        final listed = {for (final t in list.items) t.txId};
        final seen = [
          for (final s in wallet.namesSent)
            if (listed.contains(s.txid)) s.txid,
        ];
        if (seen.isNotEmpty) await wallet.forgetNamesSent(seen);
        if (!mounted || request != _request) return;
        setState(() {
          _incoming = list;
          _sent = wallet.namesSent;
        });
      }
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(
        () => _error = l10n.pivxNamesLoadTransactionsFailed(pivxNamesError(e)),
      );
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _switch(bool refunds) {
    if (refunds == _refunds) return;
    setState(() {
      _refunds = refunds;
      _page = 1;
    });
    unawaited(_load());
  }

  Future<void> _open(PivxNamesTracked tracked) async {
    await Navigator.of(context)
        .pushNamed(PivxNamesStatusView.routeName, arguments: tracked);
    if (mounted) unawaited(_load());
  }

  Future<void> _showMemo(String memo) => showDialog<void>(
    context: context,
    builder: (context) {
      final colors = Theme.of(context).extension<StackColors>()!;
      return StackDialog(
        title: l10n.pivxNamesTransactionMemo,
        message: memo,
        leftButton: TextButton(
          style: colors.getSecondaryEnabledButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            l10n.commonClose,
            style: STextStyles.button(context)
                .copyWith(color: colors.accentColorDark),
          ),
        ),
        rightButton: TextButton(
          style: colors.getPrimaryEnabledButtonStyle(context),
          onPressed: () async {
            await pivxNamesCopy(context, memo, l10n.commonMemo);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(l10n.commonCopy, style: STextStyles.button(context)),
        ),
      );
    },
  );

  Widget _tabs() {
    final colors = Theme.of(context).extension<StackColors>()!;
    Widget tab(String label, String icon, bool refunds) {
      final selected = _refunds == refunds;
      return Expanded(
        child: Material(
          color: selected ? colors.accentColorBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _switch(refunds),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  PivxNamesIcon(
                    icon,
                    size: 16,
                    color: selected
                        ? colors.buttonTextPrimary
                        : colors.textSubtitle1,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: STextStyles.w600_14(context).copyWith(
                      color: selected
                          ? colors.buttonTextPrimary
                          : colors.textSubtitle1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.textFieldDefaultBG,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          tab(l10n.pivxNamesIncoming, PivxNamesIcons.incoming, false),
          const SizedBox(width: 4),
          tab(l10n.pivxNamesRefunds, PivxNamesIcons.refunds, true),
        ],
      ),
    );
  }

  Widget _txIdRow(String txId) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => pivxNamesCopy(context, txId, l10n.commonTransactionId),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              pivxNamesShortId(txId),
              style: STextStyles.w500_12(
                context,
              ).copyWith(fontFamily: "monospace", color: colors.textSubtitle1),
            ),
            const SizedBox(width: 4),
            Icon(Icons.copy_rounded, size: 12, color: colors.textSubtitle1),
          ],
        ),
      ),
    );
  }

  Widget _card({
    required String name,
    required String op,
    required Widget status,
    String? confirmations,
    String? txId,
    String? memo,
    String? note,
    VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RoundedWhiteContainer(
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: PivxNamesNameText(
                        name,
                        style: STextStyles.w600_14(context),
                      ),
                    ),
                    PivxNamesPill(text: op, color: colors.accentColorBlue),
                    if (onTap != null) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: colors.textSubtitle1,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    status,
                    if (confirmations != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        l10n.pivxNamesConfirmations(confirmations),
                        style: secondary,
                      ),
                    ],
                  ],
                ),
                if (note != null) ...[
                  const SizedBox(height: 6),
                  Text(note, style: secondary),
                ],
                if (txId != null || memo != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (txId != null && txId.isNotEmpty) _txIdRow(txId),
                      const Spacer(),
                      if (memo != null && memo.isNotEmpty)
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => _showMemo(memo),
                          child: Text(
                            l10n.pivxNamesShowMemo,
                            style: STextStyles.w600_12(context)
                                .copyWith(color: colors.accentColorBlue),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _incomingList() {
    final list = _incoming;
    final items = list?.items ?? const <PivxNamesIncoming>[];
    final listed = {for (final t in items) t.txId};
    final sent = _page == 1
        ? [
            for (final s in _sent)
              if (!listed.contains(s.txid)) s,
          ]
        : const <PivxNamesSent>[];
    return [
      for (final s in sent)
        _card(
          name: s.name,
          op: s.op,
          status: const PivxNamesStatusPill(status: null),
          note: l10n.pivxNamesSentWaiting,
          txId: s.txid,
          memo: s.memo,
          onTap: () => _open(
            PivxNamesTracked(
              walletId: widget.walletId,
              name: s.name,
              op: s.op,
              memo: s.memo,
              txId: s.txid,
            ),
          ),
        ),
      for (final t in items)
        _card(
          name: t.name,
          op: t.op,
          status: PivxNamesStatusPill(status: t.status, raw: t.rawStatus),
          confirmations: switch (t.status) {
            PivxNamesTxStatus.confirmingPayment =>
              "${t.confirmations}/$_paymentConfirmations",
            PivxNamesTxStatus.pendingRefund =>
              "${t.confirmations}/$_refundConfirmations",
            _ => null,
          },
          txId: t.txId,
          memo: t.memo,
          onTap:
              t.status == null ||
                  t.status!.isFinal ||
                  t.txId.isEmpty ||
                  !isValidPivxName(t.name)
              ? null
              : () => _open(
                  PivxNamesTracked(
                    walletId: widget.walletId,
                    name: t.name,
                    op: t.op,
                    memo: t.memo.isEmpty ? null : t.memo,
                    txId: t.txId,
                  ),
                ),
        ),
    ];
  }

  List<Widget> _refundsList() {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    String day(DateTime d) =>
        "${d.year}-${d.month.toString().padLeft(2, "0")}-"
        "${d.day.toString().padLeft(2, "0")} UTC";
    return [
      for (final r in _refundList?.items ?? const <PivxNamesRefund>[])
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: RoundedWhiteContainer(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        pivxNamesAmount(r.amount, ref, wallet),
                        style: STextStyles.w600_16(context),
                      ),
                    ),
                    PivxNamesPill(
                      text:
                          r.status?.label ??
                          l10n.pivxNamesStatusCode("${r.rawStatus ?? "?"}"),
                      color: pivxNamesReadable(switch (r.status) {
                        PivxNamesRefundStatus.paid => colors.accentColorGreen,
                        PivxNamesRefundStatus.error => colors.accentColorRed,
                        _ => colors.accentColorBlue,
                      }, colors),
                      icon: r.status == PivxNamesRefundStatus.error
                          ? PivxNamesIcons.warning
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if (r.date != null) day(r.date!),
                    if (r.fee.isNotEmpty) l10n.pivxNamesFeePercent(r.fee),
                  ].join("  ·  "),
                  style: secondary,
                ),
                if (r.txId.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _txIdRow(r.txId),
                  ),
                ],
              ],
            ),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final rows = _refunds ? _refundsList() : _incomingList();
    final count = _refunds ? _refundList?.count : _incoming?.count;
    final shown = _refunds ? _refundList : _incoming;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PivxNamesAppBar(
          walletId: widget.walletId,
          title: l10n.pivxNamesMyTransactions,
          section: PivxNamesSection.transactions,
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Row(
                  children: [
                    Expanded(child: _tabs()),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: l10n.commonRefresh,
                      onPressed: _loading ? null : _load,
                      icon: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.refresh_rounded,
                              color: colors.accentColorBlue,
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _refunds
                      ? l10n.pivxNamesRefundsIntro
                      : l10n.pivxNamesIncomingIntro,
                  style: STextStyles.itemSubtitle(context),
                ),
                const SizedBox(height: 12),
                if (_error != null) ...[
                  PivxNamesListState(error: _error, onRetry: _load),
                  // What this wallet sent still shows.
                  if (!_refunds) ...rows,
                ] else if (shown == null && _loading)
                  const PivxNamesListState(loading: true)
                else if (rows.isEmpty)
                  PivxNamesListState(
                    empty: _refunds
                        ? l10n.pivxNamesNoWithdrawals
                        : l10n.pivxNamesNoPayments,
                  )
                else ...[
                  ...rows,
                  PivxNamesPager(
                    page: _page,
                    count: count ?? 0,
                    pageSize: kPivxNamesHistoryPageSize,
                    onPage: (p) {
                      setState(() => _page = p);
                      unawaited(_load());
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
