import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/global/wallets_provider.dart';
import '../../services/pivx_name/pivx_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/rounded_white_container.dart';
import 'pivx_names_common.dart';
import 'pivx_names_in_flight.dart';

/// A paid command to follow: by its memo until the registrar finds its
/// transaction, then by [txId].
class PivxNamesTracked {
  const PivxNamesTracked({
    required this.walletId,
    required this.name,
    required this.op,
    required this.memo,
    required this.txId,
  });

  final String walletId;
  final String name;

  /// The operation's code ("REG").
  final String op;
  final String? memo;
  final String? txId;
}

/// Where a paid command is: found on the network, confirmed, proved, done
/// (or refunded). Asks the registrar every 30 seconds, as the web app
/// does, until nothing more will happen.
class PivxNamesStatusView extends ConsumerStatefulWidget {
  const PivxNamesStatusView({super.key, required this.tracked});

  static const routeName = "/pivxNamesStatus";

  final PivxNamesTracked tracked;

  @override
  ConsumerState<PivxNamesStatusView> createState() =>
      _PivxNamesStatusViewState();
}

class _PivxNamesStatusViewState extends ConsumerState<PivxNamesStatusView> {
  static const _interval = 30;

  late String? _txId = widget.tracked.txId;
  PivxNamesProgress? _progress;
  int _paymentConfirmations = 40;
  int _refundConfirmations = 120;
  int _countdown = _interval;
  bool _polling = false;
  bool _offline = false;
  Timer? _timer;

  PivxNamesTracked get _t => widget.tracked;

  PivxNamesRegistrar get _registrar {
    final wallet = ref.read(pWallets).getWallet(_t.walletId) as PivxWallet;
    return PivxNamesRegistrar.forCoin(wallet.cryptoCurrency)!;
  }

  bool get _final => _progress?.status?.isFinal ?? false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTargets());
    unawaited(_poll());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_final) return;
      setState(() => _countdown--);
      if (_countdown <= 0) unawaited(_poll());
    });
  }

  Future<void> _loadTargets() async {
    try {
      final info = await _registrar.paymentInfo();
      if (mounted) {
        setState(() {
          _paymentConfirmations = info.paymentConfirmations;
          _refundConfirmations = info.refundConfirmations;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    pivxNamesChanged();
    super.dispose();
  }

  /// A final status: no more checks, and the Names screens underneath
  /// reload.
  void _finished() {
    _timer?.cancel();
    PivxNamesInFlight.finished(_t);
    pivxNamesChanged();
  }

  Future<void> _poll() async {
    if (_polling || _final) return;
    _polling = true;
    setState(() => _countdown = _interval);
    try {
      final registrar = _registrar;
      final txId = _txId;
      final memo = _t.memo;
      if (txId == null && memo != null) {
        final found = await registrar.progressByMemo(_t.name, memo);
        if (!mounted) return;
        setState(() => _offline = false);
        if (found.txId == null) return;
        setState(() {
          _txId = found.txId;
          _progress = found;
        });
        if (_final) {
          _finished();
          return;
        }
        // Found: its status right away, not in 30 seconds.
        _polling = false;
        await _poll();
        return;
      }
      if (txId == null) return;
      final progress = await registrar.progressByTxId(_t.name, txId);
      if (!mounted) return;
      setState(() {
        _offline = false;
        // An empty answer (not seen yet) keeps what is known.
        if (progress.status != null) _progress = progress;
      });
      if (_final) _finished();
    } catch (_) {
      // Tried again at the next check, as the web app does.
      if (mounted) setState(() => _offline = true);
    } finally {
      _polling = false;
    }
  }

  String get _success => switch (_t.op) {
    "BUY" => "You've bought ${_t.name}!",
    "UPD" => "${_t.name} now points to its new address!",
    "CHG" => "${_t.name} now belongs to its new owner!",
    "LST" => "${_t.name} is listed on the marketplace!",
    "ULT" => "${_t.name} is off the marketplace!",
    _ => "You've registered ${_t.name}!",
  };

  /// "3 minutes 20 seconds", "3 minutes" or "20 seconds".
  static String _time(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return [
      if (m > 0) "$m ${m == 1 ? "minute" : "minutes"}",
      if (s > 0 || m == 0) "$s ${s == 1 ? "second" : "seconds"}",
    ].join(" ");
  }

  (String, String) get _text {
    final p = _progress;
    final status = p?.status;
    final confirmations = p?.confirmations ?? 0;
    final seconds = p?.seconds;
    return switch (status) {
      null when _txId == null => (
        "Looking for your payment…",
        "Waiting for your payment to reach the network.",
      ),
      null => (
        "Waiting for confirmation",
        "Your transaction is on the network.",
      ),
      PivxNamesTxStatus.confirmingPayment => (
        "Confirmed $confirmations/$_paymentConfirmations",
        "Waiting for the payment's confirmations.",
      ),
      PivxNamesTxStatus.pendingRefund => (
        "Confirmed $confirmations/$_refundConfirmations",
        "Waiting for the refund's confirmations.",
      ),
      PivxNamesTxStatus.pendingProof || PivxNamesTxStatus.queuedProof => (
        "Waiting for the ZK proof…",
        seconds != null && seconds > 0
            ? "It starts in about ${_time(seconds)}."
            : "It's about to start.",
      ),
      PivxNamesTxStatus.processingProof => (
        "Creating the ZK proof…",
        "Checking the cryptographic proofs.",
      ),
      PivxNamesTxStatus.submittingProof => (
        "Submitting the ZK proof…",
        "Almost done.",
      ),
      PivxNamesTxStatus.done => ("Congrats!", _success),
      PivxNamesTxStatus.refunded => (
        "Payment refunded",
        "Something in the payment was wrong, or someone else got the name "
            "first. The amount is back in your PIVX.name balance (My "
            "Balance).",
      ),
      PivxNamesTxStatus.orphaned => (
        "Payment unsuccessful",
        "The transaction seems to be orphaned because of PIVX network "
            "issues.",
      ),
      PivxNamesTxStatus.rejected => (
        "Transaction not accepted",
        "PIVX.name rejected the transaction because it doesn't follow the "
            "protocol rules.",
      ),
    };
  }

  Widget _icon(StackColors colors) {
    final status = _progress?.status;
    if (status == null || !status.isFinal) {
      return SizedBox(
        width: 72,
        height: 72,
        child: CircularProgressIndicator(
          strokeWidth: 6,
          color: colors.accentColorBlue,
          backgroundColor: colors.accentColorBlue.withValues(alpha: 0.15),
        ),
      );
    }
    final color = pivxNamesReadable(
      status.failed ? colors.accentColorRed : colors.accentColorGreen,
      colors,
    );
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Center(
        child: PivxNamesIcon(
          status.failed ? PivxNamesIcons.cross : PivxNamesIcons.check,
          size: 38,
          color: color,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final (heading, description) = _text;
    final status = _progress?.status;
    final txId = _txId;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: pivxNamesFlowAppBar(context, _t.name),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    PivxNamesSteps(
                      step: status == PivxNamesTxStatus.done
                          ? PivxNamesStep.done
                          : PivxNamesStep.pay,
                    ),
                    const SizedBox(height: 36),
                    Center(
                      child: SizedBox(
                        width: 88,
                        height: 88,
                        child: Center(child: _icon(colors)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      heading,
                      textAlign: TextAlign.center,
                      style: STextStyles.pageTitleH1(context),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 20),
                    if (!_final)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: colors.textFieldDefaultBG,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PivxNamesIcon(
                                PivxNamesIcons.clock,
                                size: 18,
                                color: colors.accentColorBlue,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _polling
                                    ? "Checking…"
                                    : "Next check in ${_countdown}s",
                                style: STextStyles.w600_14(context),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_offline && !_final) ...[
                      const SizedBox(height: 8),
                      Text(
                        "Couldn't reach PIVX.name. Trying again at the next "
                        "check.",
                        textAlign: TextAlign.center,
                        style: STextStyles.w500_12(context)
                            .copyWith(color: colors.textSubtitle1),
                      ),
                    ],
                    if (!_final) ...[
                      const SizedBox(height: 24),
                      RoundedWhiteContainer(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: colors.accentColorBlue,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                "You can close this screen: nothing stops. "
                                "Follow the payment in My Transactions and "
                                "tap it there to come back here.",
                                style: STextStyles.w500_12(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (txId != null) ...[
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton.icon(
                          onPressed: () =>
                              pivxNamesCopy(context, txId, "Transaction ID"),
                          icon: Icon(
                            Icons.copy_rounded,
                            size: 14,
                            color: colors.textSubtitle1,
                          ),
                          label: Text(
                            "Transaction ${pivxNamesShortId(txId)}",
                            style: STextStyles.w500_12(context)
                                .copyWith(color: colors.textSubtitle1),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: SecondaryButton(
                        label: "My Transactions",
                        onPressed: () => Navigator.of(context)
                            .pushReplacementNamed(
                              PivxNamesSection.transactions.routeName,
                              arguments: _t.walletId,
                            ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: PrimaryButton(
                        label: _final ? "Done" : "Close",
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
