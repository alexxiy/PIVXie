import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
import '../../services/pivx_defi/pivx_defi_api.dart';
import '../../services/pivx_defi/pivx_defi_models.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/logger.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/desktop_page_column.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/qr.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_dialog.dart';
import '../send_view/confirm_transaction_view.dart';
import '../send_view/sub_widgets/building_transaction_dialog.dart';
import '../send_view/sub_widgets/pivx_funding_card.dart';
import 'pivx_defi_common.dart';

/// Opens the order [id] (with [order] when it is at hand).
Future<void> openPivxDefiOrder(
  BuildContext context, {
  required String walletId,
  required String id,
  PivxDefiOrder? order,
}) => Navigator.of(context).push(
  RouteGenerator.getRoute<void>(
    shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
    builder: (_) => DesktopPageColumn(
      child: PivxDefiOrderView(walletId: walletId, orderId: id, order: order),
    ),
    settings: const RouteSettings(name: PivxDefiOrderView.routeName),
  ),
);

/// A DeFi Bridge order and how far it got, as the web app's order page
/// shows it. A wrap is paid here, from this wallet or another; an unwrap
/// shows where its wPIVX goes, once the token itself confirms the address.
class PivxDefiOrderView extends ConsumerStatefulWidget {
  const PivxDefiOrderView({
    super.key,
    required this.walletId,
    required this.orderId,
    this.order,
  });

  static const routeName = "/pivxDefiOrder";

  final String walletId;
  final String orderId;

  /// The order as just created, to draw before the first answer.
  final PivxDefiOrder? order;

  @override
  ConsumerState<PivxDefiOrderView> createState() => _PivxDefiOrderViewState();
}

/// Whether an unwrap's deposit address is the token's own for the order's
/// PIVX address.
enum _Deposit { checking, ok, unavailable, mismatch }

/// How the status card looks.
enum _Kind { progress, success, error }

const _kDepositRetry = Duration(seconds: 15);

class _PivxDefiOrderViewState extends ConsumerState<PivxDefiOrderView>
    with WidgetsBindingObserver {
  late final PivxDefiApi _api;
  late final PivxDefiChain _chain;

  PivxDefiOrder? _order;
  var _notFound = false;
  var _failures = 0;
  Timer? _poll;

  /// The app went to the background with a poll due: it runs on return.
  var _suspended = false;
  var _inBackground = false;

  PivxDefiInfo? _info;

  /// The wrap's payment was sent from here, or the user said it was paid.
  var _paid = false;

  /// "Pay from another wallet" is open.
  var _elsewhere = false;
  late PivxFunding _funding;
  var _fundingChosen = false;
  var _paying = false;

  var _deposit = _Deposit.checking;
  String? _depositChecked;
  Timer? _depositTimer;
  var _depositSeq = 0;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  PivxDefiRecentOrder? get _recent => _wallet.defiOrder(widget.orderId);

  String get _chainName => _info?.chainName ?? "BNB Smart Chain";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final coin = _wallet.cryptoCurrency;
    _api = PivxDefiApi.forCoin(coin)!;
    _chain = PivxDefiChain(_api.config);
    _info = pivxDefiLastInfo;
    _paid = _recent?.paid ?? false;
    _funding = _defaultFunding(widget.order?.payment?.amount);
    final order = widget.order;
    if (order != null) _setOrder(order, draw: false);
    _schedule(
      order == null ? Duration.zero : pivxDefiPollDelay(order, paid: _paid),
    );
    unawaited(_loadInfo());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _depositTimer?.cancel();
    _depositSeq++;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inBackground =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (!_inBackground && _suspended) {
      _suspended = false;
      unawaited(_pollOrder());
    }
  }

  Future<void> _loadInfo() async {
    try {
      final info = await loadPivxDefiInfo(_api);
      if (mounted) setState(() => _info = info);
    } catch (e, s) {
      Logging.instance.w("DeFi Bridge info failed", error: e, stackTrace: s);
    }
  }

  // --- polling ---------------------------------------------------------------

  void _schedule(Duration? delay) {
    _poll?.cancel();
    if (delay == null || !mounted || _notFound) return;
    _poll = Timer(delay, _pollOrder);
  }

  Future<void> _pollOrder() async {
    if (!mounted) return;
    if (_inBackground) {
      _suspended = true;
      return;
    }
    try {
      final order = await _api.order(widget.orderId);
      if (!mounted) return;
      _failures = 0;
      _setOrder(order);
      _schedule(pivxDefiPollDelay(order, paid: _paid));
    } catch (e, s) {
      if (!mounted) return;
      if (e is PivxDefiApiException && e.status == 404) {
        _poll?.cancel();
        setState(() => _notFound = true);
        return;
      }
      Logging.instance.w("DeFi Bridge order failed", error: e, stackTrace: s);
      _failures++;
      if (_failures == 3) {
        unawaited(pivxDefiToast(context, l10n.defiErrorNetworkRetry));
      }
      _schedule(
        Duration(
          milliseconds: math.min(4000 * math.pow(2, _failures).toInt(), 60000),
        ),
      );
    }
  }

  /// Takes a new answer. The same answer again only redraws the time left
  /// to pay.
  void _setOrder(PivxDefiOrder order, {bool draw = true}) {
    final old = _order;
    final same = old != null && jsonEncode(old.json) == jsonEncode(order.json);
    _order = order;
    if (!_fundingChosen && old?.payment == null && order.payment != null) {
      _funding = _defaultFunding(order.payment!.amount);
    }
    if (!order.isWrap) _checkDeposit(order);
    if (!draw) return;
    if (!same || order.status == "awaiting_payment") setState(() {});
  }

  // --- the wrap's payment ----------------------------------------------------

  /// The shielded balance when it pays [sat], else the transparent one
  /// when that does; else whichever has coins, shielded first.
  PivxFunding _defaultFunding(int? sat) {
    final wallet = _wallet;
    final shield = ref.read(pWalletBalanceSecondary(widget.walletId)).spendable;
    final transparent = ref.read(pWalletBalance(widget.walletId)).spendable;
    final want = sat == null
        ? null
        : Amount(
            rawValue: BigInt.from(sat),
            fractionDigits: wallet.cryptoCurrency.fractionDigits,
          );
    bool pays(Amount balance) =>
        want == null ? balance > Amount.zero : balance > want;
    final fromShield =
        wallet.supportsShield &&
        (pays(shield) || (!pays(transparent) && shield > Amount.zero));
    return (fromShield: fromShield, coins: const {}, changeAddress: null);
  }

  /// Whether the order is the one this wallet asked for, so it can be paid
  /// from here: the amount, the recipient and the memo as the user entered
  /// them, and the bridge's own address to pay. Null: it can be paid.
  String? _payProblem(PivxDefiOrder order) {
    final payment = order.payment;
    final recent = _recent;
    final info = _info;
    if (payment == null || recent == null || recent.to == null) {
      return l10n.defiErrorOrderMismatch;
    }
    final swap = PivxDefiSwap(
      direction: PivxDefiDirection.wrap,
      amount: recent.amount,
      evmAddress: recent.to,
    );
    if (!pivxDefiOrderMatches(order, swap)) return l10n.defiErrorOrderMismatch;
    if (info != null && !info.bridgeAddresses.contains(payment.address)) {
      return l10n.defiErrorOrderMismatch;
    }
    return null;
  }

  Future<void> _setPaid(bool paid) async {
    setState(() => _paid = paid);
    await _wallet.setDefiOrderPaid(widget.orderId, paid);
    pivxDefiChanged();
    final order = _order;
    if (order != null) _schedule(pivxDefiPollDelay(order, paid: paid));
  }

  Future<void> _pay(PivxDefiOrder order) async {
    if (_paying) return;
    final payment = order.payment;
    final info = _info;
    // The bridge's own address, checked against its settings: they come
    // again first if they are missing.
    if (payment == null || info == null) {
      await _loadInfo();
      if (!mounted || _info == null) {
        if (mounted) await pivxDefiToast(context, l10n.defiErrorNetwork);
        return;
      }
    }
    if (payment == null || _payProblem(order) != null) return;
    if (order.status != "awaiting_payment") return;
    final expires = order.expires;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (expires != null && expires <= now) return;

    setState(() => _paying = true);
    try {
      final wallet = _wallet;
      final coin = wallet.cryptoCurrency;
      final txData = await showBuildingTransaction<TxData>(
        context: context,
        coin: coin,
        build: () => wallet.prepareDefiWrapPayment(
          address: payment.address,
          amount: Amount(
            rawValue: BigInt.from(payment.amount),
            fractionDigits: coin.fractionDigits,
          ),
          memo: payment.memo,
          note: "${l10n.defiTitle} · ${order.id}",
          funding: _funding,
        ),
      );
      if (!mounted || txData == null) return;
      final navigator = Navigator.of(context);
      await navigator.push(
        RouteGenerator.getRoute<void>(
          shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
          builder: (_) => DesktopPageColumn(
            card: true,
            child: ConfirmTransactionView(
              txData: txData,
              walletId: widget.walletId,
              onSuccess: () {},
              // Marked before it leaves: a payment sent twice would wrap
              // twice as much.
              beforeBroadcast: () =>
                  wallet.setDefiOrderPaid(widget.orderId, true),
              afterFailedBroadcast: () =>
                  wallet.setDefiOrderPaid(widget.orderId, false),
              onSuccessInsteadOfRouteOnSuccess: () {
                navigator.popUntil(
                  ModalRoute.withName(PivxDefiOrderView.routeName),
                );
                if (!mounted) return;
                setState(() => _paid = true);
                pivxDefiChanged();
                _schedule(const Duration(seconds: 2));
              },
            ),
          ),
          settings: const RouteSettings(name: ConfirmTransactionView.routeName),
        ),
      );
    } catch (e, s) {
      Logging.instance.w("DeFi Bridge payment failed", error: e, stackTrace: s);
      if (mounted) await pivxDefiToast(context, e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _paying = false;
          // Back from the confirm screen without sending.
          _paid = _recent?.paid ?? _paid;
        });
      }
    }
  }

  Future<void> _showQr(PivxDefiOrder order) async {
    final p = order.payment;
    if (p == null) return;
    // Same link as the web app's: the memo percent-encoded so "&" or "="
    // cannot cut it, the ":" between the order and the address readable.
    final memo = Uri.encodeComponent(p.memo).replaceAll("%3A", ":");
    final uri =
        "pivx:${p.address}?amount=${formatPivxDefiAmount(p.amount)}&memo=$memo";
    final colors = Theme.of(context).extension<StackColors>()!;
    await showDialog<void>(
      context: context,
      builder: (context) => StackDialog(
        title: l10n.defiQrTitle,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: QR(data: uri, size: 240)),
            const SizedBox(height: 12),
            Text(
              l10n.defiQrWarning,
              style: STextStyles.w500_12(context)
                  .copyWith(color: pivxDefiWarning(colors)),
            ),
          ],
        ),
        rightButton: TextButton(
          style: colors.getPrimaryEnabledButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose, style: STextStyles.button(context)),
        ),
      ),
    );
  }

  // --- the unwrap's deposit address ------------------------------------------

  /// Asks the token on BNB Smart Chain, through several endpoints, which
  /// deposit address belongs to the order's PIVX address. The bridge's
  /// own answer is shown only when they agree with it, and only for the
  /// PIVX address this wallet asked to be paid at.
  void _checkDeposit(PivxDefiOrder order) {
    final pivx = order.pivxAddress;
    final deposit = order.depositAddress;
    final key = "$pivx|$deposit";
    if (key == _depositChecked) return;
    _depositChecked = key;
    _depositTimer?.cancel();
    final seq = ++_depositSeq;
    final recent = _recent;
    if (pivx == null ||
        deposit == null ||
        (recent != null && recent.to != null && recent.to != pivx)) {
      _deposit = _Deposit.mismatch;
      return;
    }
    _deposit = _Deposit.checking;
    unawaited(_askChain(seq, pivx, deposit));
  }

  Future<void> _askChain(int seq, String pivx, String deposit) async {
    _Deposit result;
    try {
      final address = await _chain.depositAddress(pivx);
      result = address == deposit.toLowerCase()
          ? _Deposit.ok
          : _Deposit.mismatch;
    } on PivxDefiChainException catch (e) {
      Logging.instance.w("DeFi Bridge deposit check: $e");
      result = e.kind == PivxDefiChainError.disagreement
          ? _Deposit.mismatch
          : _Deposit.unavailable;
    } catch (e) {
      Logging.instance.w("DeFi Bridge deposit check: $e");
      result = _Deposit.unavailable;
    }
    if (seq != _depositSeq || !mounted) return;
    setState(() => _deposit = result);
    if (result == _Deposit.unavailable) {
      _depositTimer = Timer(_kDepositRetry, () => _retryDeposit(seq));
    }
  }

  void _retryDeposit(int seq) {
    if (seq != _depositSeq || !mounted) return;
    final order = _order;
    if (order == null) return;
    _depositChecked = null;
    setState(() => _checkDeposit(order));
  }

  // --- the status card -------------------------------------------------------

  void _newSwap() {
    final navigator = Navigator.of(context);
    var found = false;
    navigator.popUntil((route) {
      if (route.settings.name == kPivxDefiRoute) found = true;
      return found || route.isFirst;
    });
    if (!found) {
      unawaited(
        navigator.pushNamed(kPivxDefiRoute, arguments: widget.walletId),
      );
    }
  }

  Widget _link(String label, Uri? uri) => SecondaryButton(
    label: label,
    buttonHeight: Util.isDesktop ? ButtonHeight.l : null,
    onPressed: () => pivxDefiOpen(uri),
  );

  Widget _newSwapButton() => SecondaryButton(
    label: l10n.defiNewOrder,
    buttonHeight: Util.isDesktop ? ButtonHeight.l : null,
    onPressed: _newSwap,
  );

  Widget _statusCard({
    required StackColors colors,
    required PivxDefiOrder order,
    required _Kind kind,
    required String heading,
    required String text,
    required List<PivxDefiStep> steps,
    required int active,
    bool failed = false,
    List<Widget> actions = const [],
  }) {
    final color = pivxDefiColor(order.direction, colors);
    final tone = switch (kind) {
      _Kind.progress => color,
      _Kind.success => pivxDefiGreen(colors),
      _Kind.error => colors.textError,
    };
    final support = _info?.supportUri;
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: switch (kind) {
                  _Kind.progress => Padding(
                    padding: const EdgeInsets.all(3),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: tone,
                    ),
                  ),
                  _Kind.success => Icon(
                    Icons.check_circle_rounded,
                    color: tone,
                  ),
                  _Kind.error => Icon(Icons.error_rounded, color: tone),
                },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  heading,
                  style: STextStyles.pageTitleH2(context).copyWith(color: tone),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(text, style: STextStyles.w500_14(context)),
          if (kind == _Kind.error && support != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: CustomTextButton(
                  text: l10n.defiSupport,
                  onTap: () => pivxDefiOpen(support),
                ),
              ),
            ),
          const SizedBox(height: 12),
          PivxDefiStepper(
            steps: steps,
            active: active,
            color: color,
            failed: failed,
          ),
          for (final a in actions) ...[const SizedBox(height: 10), a],
        ],
      ),
    );
  }

  Widget _wrapProgress(StackColors colors, PivxDefiOrder order) {
    final n = order.confirmationsRequired;
    final conf = order.wrapConfirmations;
    final mintTx = order.mintTx;
    final received = order.received;
    final mintUrl = _info?.evmTxUrl(mintTx);
    final steps = <PivxDefiStep>[
      (
        label: l10n.defiStepWrapPay,
        sub: order.seenTxid != null || order.deposits.isNotEmpty
            ? l10n.defiStepWrapPaySeen
            : l10n.defiStepWrapPayWait,
        progress: null,
      ),
      (
        label: l10n.defiStepWrapConfirm,
        sub: l10n.defiStepConfirmations(conf.toString(), n.toString()),
        progress: conf / n,
      ),
      (
        label: l10n.defiStepWrapMint,
        sub: order.status == "completed"
            ? l10n.defiStepMintDone
            : mintTx != null
            ? l10n.defiStepMintSent
            : l10n.defiStepMintQueue,
        progress: null,
      ),
      (label: l10n.defiStepDone, sub: null, progress: null),
    ];
    final actions = <Widget>[];
    if (order.status != "closed" && received > 0 && received != order.amount) {
      actions.add(
        PivxDefiNote(
          text: l10n.defiAmountDiffers(
            showPivxDefiAmount(received),
            showPivxDefiAmount(order.amount),
          ),
          color: pivxDefiWarning(colors),
          icon: Icons.warning_amber_rounded,
        ),
      );
    }
    Widget card(
      _Kind kind,
      String heading,
      String text,
      int active, {
      bool failed = false,
    }) => _statusCard(
      colors: colors,
      order: order,
      kind: kind,
      heading: heading,
      text: text,
      steps: steps,
      active: active,
      failed: failed,
      actions: actions,
    );
    switch (order.status) {
      case "awaiting_payment":
        actions.add(
          SecondaryButton(
            label: l10n.defiShowPayment,
            buttonHeight: Util.isDesktop ? ButtonHeight.l : null,
            onPressed: () => _setPaid(false),
          ),
        );
        return card(
          _Kind.progress,
          l10n.defiStatusAwaitingPayment,
          l10n.defiStatusAwaitingPaymentText,
          0,
        );
      case "payment_seen":
        return card(
          _Kind.progress,
          l10n.defiStatusPaymentSeen,
          l10n.defiStatusPaymentSeenText,
          1,
        );
      case "expired":
        actions.add(_newSwapButton());
        return card(
          _Kind.error,
          l10n.defiStatusExpired,
          l10n.defiStatusExpiredText,
          0,
          failed: true,
        );
      case "confirming":
        return card(
          _Kind.progress,
          l10n.defiStatusConfirming,
          l10n.defiStatusConfirmingText(
            n.toString(),
            math.max(1, (n - conf) * kPivxDefiBlockMinutes).toString(),
          ),
          1,
        );
      case "minting":
        if (mintUrl != null) actions.add(_link(l10n.defiViewMint, mintUrl));
        return card(
          _Kind.progress,
          l10n.defiStatusMinting,
          l10n.defiStatusMintingText(_chainName),
          2,
        );
      case "completed":
        if (mintUrl != null) actions.add(_link(l10n.defiViewMint, mintUrl));
        actions.add(_newSwapButton());
        return card(
          _Kind.success,
          l10n.defiStatusCompleted,
          l10n.defiStatusCompletedWrap(
            showPivxDefiAmount(order.minted),
            shortEvmAddress(order.evmAddress ?? ""),
          ),
          steps.length,
        );
      case "closed":
        return card(
          _Kind.error,
          l10n.defiStatusClosed,
          l10n.defiStatusClosedWrapText(order.id),
          1,
          failed: true,
        );
      default:
        return card(
          _Kind.error,
          l10n.defiStatusAttention,
          l10n.defiStatusAttentionText(order.id),
          order.deposits.any((d) => d.status == "completed") ? 2 : 1,
          failed: true,
        );
    }
  }

  /// Where to send the wPIVX: shown once the token confirms it.
  Widget _depositPanel(StackColors colors, PivxDefiOrder order, int needed) {
    switch (_deposit) {
      case _Deposit.checking:
        return Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.defiDepositChecking(_chainName),
                style: STextStyles.w500_12(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
            ),
          ],
        );
      case _Deposit.unavailable:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PivxDefiNote(
              text: l10n.defiDepositUnavailable(_chainName),
              color: pivxDefiWarning(colors),
              icon: Icons.cloud_off_rounded,
            ),
            const SizedBox(height: 8),
            SecondaryButton(
              label: l10n.commonTryAgain,
              buttonHeight: Util.isDesktop ? ButtonHeight.l : null,
              onPressed: () {
                _depositTimer?.cancel();
                _retryDeposit(_depositSeq);
              },
            ),
          ],
        );
      case _Deposit.mismatch:
        return PivxDefiNote(
          text: l10n.defiErrorDepositMismatch,
          color: colors.textError,
          icon: Icons.gpp_bad_rounded,
        );
      case _Deposit.ok:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PivxDefiCopyBox(
              label: l10n.defiDepositLabel(showPivxDefiAmount(needed)),
              value: order.depositAddress!,
              color: pivxDefiColor(order.direction, colors),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.defiDepositNote(_chainName),
              style: STextStyles.w500_12(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
          ],
        );
    }
  }

  Widget _unwrapProgress(StackColors colors, PivxDefiOrder order) {
    const finalStates = {
      "payout_pending",
      "payout_held",
      "payout_sent",
      "completed",
    };
    final isFinal = finalStates.contains(order.status);
    final received =
        isFinal || order.status == "burn_queued" || order.status == "burning";
    final confirming = order.status == "payout_sent";
    final n = order.confirmationsRequired;
    final conf = math.min(order.burn?.payoutConfirmations ?? 0, n);
    final steps = <PivxDefiStep>[
      (
        label: l10n.defiStepUnwrapSend,
        sub: order.evmTxHash != null || received
            ? l10n.defiStepSendDone
            : l10n.defiStepSendWait,
        progress: null,
      ),
      (
        label: l10n.defiStepUnwrapBurn(_chainName),
        sub: isFinal
            ? l10n.defiStepBurnDone
            : order.status == "burning"
            ? l10n.defiStepBurnSent
            : l10n.defiStepBurnQueue,
        progress: null,
      ),
      (
        label: l10n.defiStepUnwrapPayout,
        sub: order.status == "completed"
            ? l10n.defiStepPayoutDone
            : confirming
            ? l10n.defiStepConfirmations(conf.toString(), n.toString())
            : l10n.defiStepPayoutQueue,
        progress: confirming ? conf / n : null,
      ),
      (label: l10n.defiStepDone, sub: null, progress: null),
    ];
    final txUrl = _info?.evmTxUrl(order.evmTxHash);
    final payoutUrl = _info?.pivxTxUrl(order.burn?.payoutTxid);
    final actions = <Widget>[];
    Widget card(
      _Kind kind,
      String heading,
      String text,
      int active, {
      bool failed = false,
    }) => _statusCard(
      colors: colors,
      order: order,
      kind: kind,
      heading: heading,
      text: text,
      steps: steps,
      active: active,
      failed: failed,
      actions: actions,
    );
    switch (order.status) {
      case "awaiting_tx":
      case "tx_failed":
        final failed = order.status == "tx_failed";
        actions.add(_depositPanel(colors, order, order.amount));
        if (txUrl != null) actions.add(_link(l10n.defiViewTransfer, txUrl));
        return failed
            ? card(
                _Kind.error,
                l10n.defiStatusTxFailed,
                l10n.defiStatusTxFailedText,
                0,
                failed: true,
              )
            : card(
                _Kind.progress,
                l10n.defiStatusAwaitingTx,
                l10n.defiStatusAwaitingTxText(showPivxDefiAmount(order.amount)),
                0,
              );
      case "below_minimum":
        final min = _info?.unwrapMin ?? 0;
        final balance = order.depositBalance;
        final rest = order.amount - balance;
        final missing = min - balance;
        actions.add(
          _depositPanel(colors, order, rest > missing ? rest : missing),
        );
        return card(
          _Kind.error,
          l10n.defiStatusBelowMinimum,
          l10n.defiStatusBelowMinimumText(
            showPivxDefiAmount(balance),
            showPivxDefiAmount(min),
          ),
          0,
          failed: true,
        );
      case "tx_pending":
        if (txUrl != null) actions.add(_link(l10n.defiViewTransfer, txUrl));
        return card(
          _Kind.progress,
          l10n.defiStatusTxPending,
          l10n.defiStatusTxPendingText(_chainName),
          1,
        );
      case "burn_queued":
        if (txUrl != null) actions.add(_link(l10n.defiViewTransfer, txUrl));
        return card(
          _Kind.progress,
          l10n.defiStatusBurnQueued,
          l10n.defiStatusBurnQueuedText,
          1,
        );
      case "burning":
        if (txUrl != null) actions.add(_link(l10n.defiViewBurn, txUrl));
        return card(
          _Kind.progress,
          l10n.defiStatusBurning,
          l10n.defiStatusBurningText(_chainName),
          1,
        );
      case "payout_pending":
        return card(
          _Kind.progress,
          l10n.defiStatusPayout,
          l10n.defiStatusPayoutText(showPivxDefiAmount(order.receive)),
          2,
        );
      case "payout_sent":
        if (payoutUrl != null) {
          actions.add(_link(l10n.defiViewPayout, payoutUrl));
        }
        return card(
          _Kind.progress,
          l10n.defiStatusPayoutSent,
          l10n.defiStatusPayoutSentText(
            showPivxDefiAmount(order.receive),
            n.toString(),
          ),
          2,
        );
      case "payout_held":
        return card(
          _Kind.error,
          l10n.defiStatusPayoutHeld,
          l10n.defiStatusPayoutHeldText(order.id),
          2,
          failed: true,
        );
      case "completed":
        if (payoutUrl != null) {
          actions.add(_link(l10n.defiViewPayout, payoutUrl));
        }
        actions.add(_newSwapButton());
        return card(
          _Kind.success,
          l10n.defiStatusCompleted,
          l10n.defiStatusCompletedUnwrap(showPivxDefiAmount(order.receive)),
          steps.length,
        );
      case "closed":
        return card(
          _Kind.error,
          l10n.defiStatusClosed,
          l10n.defiStatusClosedText(order.id),
          2,
          failed: true,
        );
      default:
        return card(
          _Kind.error,
          l10n.defiStatusAttention,
          l10n.defiStatusAttentionText(order.id),
          order.burn != null ? 2 : 1,
          failed: true,
        );
    }
  }

  // --- paying a wrap ---------------------------------------------------------

  Widget _payPanel(StackColors colors, PivxDefiOrder order) {
    final payment = order.payment!;
    final problem = _info == null ? null : _payProblem(order);
    final color = pivxDefiColor(order.direction, colors);
    final amount = Amount(
      rawValue: BigInt.from(payment.amount),
      fractionDigits: _wallet.cryptoCurrency.fractionDigits,
    );
    final expires = order.expires;

    if (problem != null) {
      // Not the order asked for: nothing here pays it.
      return PivxDefiNote(
        text: problem,
        color: colors.textError,
        icon: Icons.gpp_bad_rounded,
      );
    }

    final here = RoundedWhiteContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.defiPayFromWallet, style: STextStyles.pageTitleH2(context)),
          const SizedBox(height: 12),
          PivxDefiRow(
            label: l10n.defiPayYouGet,
            value: pivxDefiAmount(order.receive, "wPIVX"),
          ),
          PivxDefiRow(
            label: l10n.defiPayToWallet,
            value: shortEvmAddress(order.evmAddress ?? ""),
            mono: true,
          ),
          if (expires != null)
            PivxDefiRow(
              label: l10n.defiPayExpires,
              value: pivxDefiTimeLeft(expires),
            ),
          const SizedBox(height: 12),
          PivxFundingCard(
            walletId: widget.walletId,
            funding: _funding,
            amount: amount,
            toShield: true,
            onChanged: (funding) => setState(() {
              _fundingChosen = true;
              _funding = funding;
            }),
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            label: l10n.defiPayButton(showPivxDefiAmount(payment.amount)),
            enabled: !_paying && _info != null,
            buttonHeight: Util.isDesktop ? ButtonHeight.l : null,
            onPressed: () => _pay(order),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.defiPayNote,
            style: STextStyles.w500_12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
        ],
      ),
    );

    final elsewhere = RoundedWhiteContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.defiPayIntro,
            style: STextStyles.w500_12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
          const SizedBox(height: 14),
          PivxDefiCopyBox(
            label: l10n.defiPayDest,
            value: payment.address,
            color: color,
          ),
          const SizedBox(height: 12),
          PivxDefiCopyBox(
            label: l10n.defiPayAmount,
            value: formatPivxDefiAmount(payment.amount),
            color: color,
          ),
          const SizedBox(height: 12),
          PivxDefiCopyBox(
            label: l10n.defiPayMemo,
            value: payment.memo,
            badge: l10n.defiPayMemoWarning,
            color: color,
          ),
          const SizedBox(height: 16),
          SecondaryButton(
            label: l10n.defiPayQr,
            buttonHeight: Util.isDesktop ? ButtonHeight.l : null,
            onPressed: () => _showQr(order),
          ),
          const SizedBox(height: 10),
          PrimaryButton(
            label: l10n.defiPayPaid,
            buttonHeight: Util.isDesktop ? ButtonHeight.l : null,
            onPressed: () => _setPaid(true),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        here,
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: CustomTextButton(
            text: l10n.defiPayOtherWallet,
            onTap: () => setState(() => _elsewhere = !_elsewhere),
          ),
        ),
        if (_elsewhere) ...[const SizedBox(height: 8), elsewhere],
      ],
    );
  }

  // --- details ---------------------------------------------------------------

  Widget _details(StackColors colors, PivxDefiOrder order) {
    final info = _info;
    final wrap = order.isWrap;
    final sendSymbol = wrap ? "PIVX" : "wPIVX";
    final receiveSymbol = wrap ? "wPIVX" : "PIVX";
    void copy(String value, String what) => pivxDefiCopy(context, value, what);
    void open(Uri? uri) => pivxDefiOpen(uri);
    final rows = <Widget>[
      PivxDefiRow(
        label: l10n.defiDetailsOrderId,
        value: order.id,
        mono: true,
        onCopy: () => copy(order.id, l10n.defiDetailsOrderId),
      ),
      PivxDefiRow(
        label: l10n.defiDetailsCreated,
        value: pivxDefiDate(order.created),
      ),
      PivxDefiRow(
        label: l10n.defiYouSend,
        value: pivxDefiAmount(order.amount, sendSymbol),
      ),
      PivxDefiRow(
        label: l10n.defiFee,
        value: pivxDefiAmount(order.fee, "PIVX"),
      ),
      PivxDefiRow(
        label: l10n.defiYouReceive,
        value: pivxDefiAmount(order.receive, receiveSymbol),
      ),
    ];
    Uri? pivxTx(String id) => info?.pivxTxUrl(id);
    Uri? evmTx(String hash) => info?.evmTxUrl(hash);
    if (wrap) {
      final evm = order.evmAddress;
      if (evm != null) {
        final url = info?.evmAddressUrl(evm);
        rows.add(
          PivxDefiRow(
            label: l10n.defiDetailsRecipient,
            value: evm,
            mono: true,
            onOpen: url == null ? null : () => open(url),
            onCopy: () => copy(evm, l10n.defiDetailsRecipient),
          ),
        );
      }
      for (var i = 0; i < order.deposits.length; i++) {
        final d = order.deposits[i];
        final label = order.deposits.length > 1
            ? l10n.defiDetailsDepositN((i + 1).toString())
            : l10n.defiDetailsDeposit;
        final url = pivxTx(d.txid);
        rows.add(
          PivxDefiRow(
            label: label,
            value:
                "${pivxDefiAmount(d.amount, "PIVX")} · ${pivxDefiShort(d.txid, tail: 0)}",
            onOpen: url == null ? null : () => open(url),
            onCopy: () => copy(d.txid, label),
          ),
        );
        final mint = d.mintTx;
        if (mint != null) {
          final mintUrl = evmTx(mint);
          rows.add(
            PivxDefiRow(
              label: l10n.defiDetailsMintTx,
              value: pivxDefiShort(mint),
              mono: true,
              onOpen: mintUrl == null ? null : () => open(mintUrl),
              onCopy: () => copy(mint, l10n.defiDetailsMintTx),
            ),
          );
        }
      }
      final seen = order.seenTxid;
      if (order.deposits.isEmpty && seen != null) {
        final url = pivxTx(seen);
        rows.add(
          PivxDefiRow(
            label: l10n.defiDetailsSeenTx,
            value: pivxDefiShort(seen, tail: 0),
            mono: true,
            onOpen: url == null ? null : () => open(url),
            onCopy: () => copy(seen, l10n.defiDetailsSeenTx),
          ),
        );
      }
    } else {
      final deposit = order.depositAddress;
      if (deposit != null && _deposit == _Deposit.ok) {
        final url = info?.evmAddressUrl(deposit);
        rows.add(
          PivxDefiRow(
            label: l10n.defiDetailsDepositAddress,
            value: deposit,
            mono: true,
            onOpen: url == null ? null : () => open(url),
            onCopy: () => copy(deposit, l10n.defiDetailsDepositAddress),
          ),
        );
      }
      // The name as this wallet resolved it: the bridge keeps it too,
      // unchecked, so it is never shown from there.
      final recent = _recent;
      final name = recent?.name;
      if (name != null && recent?.to == order.pivxAddress) {
        rows.add(
          PivxDefiRow(
            label: l10n.defiDetailsPivxName,
            value: name,
            onCopy: () => copy(name, l10n.defiDetailsPivxName),
          ),
        );
      }
      final pivx = order.pivxAddress;
      if (pivx != null) {
        rows.add(
          PivxDefiRow(
            label: l10n.defiReviewPivxAddress,
            value: pivx,
            mono: true,
            onCopy: () => copy(pivx, l10n.defiReviewPivxAddress),
          ),
        );
      }
      final hash = order.evmTxHash;
      if (hash != null) {
        final burned = order.burn != null || order.status == "burning";
        final label = burned
            ? l10n.defiDetailsBurnTx
            : l10n.defiDetailsTransferTx;
        final url = evmTx(hash);
        rows.add(
          PivxDefiRow(
            label: label,
            value: pivxDefiShort(hash),
            mono: true,
            onOpen: url == null ? null : () => open(url),
            onCopy: () => copy(hash, label),
          ),
        );
      }
      final payout = order.burn?.payoutTxid;
      if (payout != null) {
        final url = pivxTx(payout);
        rows.add(
          PivxDefiRow(
            label: l10n.defiDetailsPayoutTx,
            value: pivxDefiShort(payout, tail: 0),
            mono: true,
            onOpen: url == null ? null : () => open(url),
            onCopy: () => copy(payout, l10n.defiDetailsPayoutTx),
          ),
        );
      }
      final later = order.laterBurns;
      if (later != null && later.count > 0) {
        rows.add(
          PivxDefiRow(
            label: l10n.defiDetailsLaterBurns,
            value: l10n.defiDetailsLaterBurnsValue(
              showPivxDefiAmount(later.amount),
              showPivxDefiAmount(later.receive),
            ),
          ),
        );
      }
      if (order.depositLeft > 0) {
        rows.add(
          PivxDefiRow(
            label: l10n.defiDetailsDepositLeft,
            value: l10n.defiDetailsDepositLeftValue(
              showPivxDefiAmount(order.depositLeft),
            ),
          ),
        );
      }
    }
    return RoundedWhiteContainer(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  // --- layout ----------------------------------------------------------------

  Widget _notFoundCard(StackColors colors) => RoundedWhiteContainer(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.defiOrderNotFound, style: STextStyles.pageTitleH2(context)),
        const SizedBox(height: 8),
        Text(l10n.defiOrderNotFoundText, style: STextStyles.w500_14(context)),
        const SizedBox(height: 16),
        _newSwapButton(),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final order = _order;
    final side = ScreenFit.sideBySide(context);

    final String title;
    final List<Widget> start;
    final List<Widget> end;
    if (_notFound) {
      title = l10n.defiOrderNotFound;
      start = [_notFoundCard(colors)];
      end = const [];
    } else if (order == null) {
      title = l10n.defiOrderLoading;
      start = [
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
      end = const [];
    } else {
      title = order.isWrap
          ? l10n.defiOrderTitleWrap(showPivxDefiAmount(order.amount))
          : l10n.defiOrderTitleUnwrap(showPivxDefiAmount(order.amount));
      final paying =
          order.isWrap &&
          order.status == "awaiting_payment" &&
          order.payment != null &&
          !_paid;
      start = [
        Center(
          child: PivxDefiPairIcon(
            coin: _wallet.cryptoCurrency,
            direction: order.direction,
            size: 36,
          ),
        ),
        const SizedBox(height: 12),
        if (paying)
          _payPanel(colors, order)
        else if (order.isWrap)
          _wrapProgress(colors, order)
        else
          _unwrapProgress(colors, order),
      ];
      end = [_details(colors, order)];
    }

    Widget column(List<Widget> children) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );

    return Background(
      child: AppScaffold(
        maxBodyWidth: ScreenFit.panesOrColumn(context),
        backgroundColor: colors.background,
        appBar: PivxDefiAppBar(
          walletId: widget.walletId,
          config: _api.config,
          title: title,
          webPath: "order/${widget.orderId}",
        ),
        body: SafeArea(
          child: side && end.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: SplitPane(start: column(start), end: column(end)),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    ...start,
                    if (end.isNotEmpty) ...[const SizedBox(height: 16), ...end],
                  ],
                ),
        ),
      ),
    );
  }
}
