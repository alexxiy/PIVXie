import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../notifications/show_flush_bar.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/pivx_name/pivx_names_protocol.dart';
import '../../services/pivx_name/pivx_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/rounded_white_container.dart';
import '../send_view/sub_widgets/pivx_funding_card.dart';
import 'pivx_names_common.dart';

/// The user's PIVX.name balance: refunds and marketplace sales, waiting to
/// be withdrawn to the wallet.
class PivxNamesBalanceView extends ConsumerStatefulWidget {
  const PivxNamesBalanceView({super.key, required this.walletId});

  static const routeName = kPivxNamesBalanceRoute;

  final String walletId;

  @override
  ConsumerState<PivxNamesBalanceView> createState() =>
      _PivxNamesBalanceViewState();
}

class _PivxNamesBalanceViewState extends ConsumerState<PivxNamesBalanceView> {
  PivxNamesBalance? _balance;
  bool _loading = true;
  String? _error;
  String? _address;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  PivxNamesRegistrar get _registrar =>
      PivxNamesRegistrar.forCoin(_wallet.cryptoCurrency)!;

  @override
  void initState() {
    super.initState();
    pivxNamesChanges.addListener(_changed);
    unawaited(_load());
    unawaited(
      _wallet.getCurrentShieldAddress().then((a) {
        if (mounted && _address == null) setState(() => _address = a);
      }),
    );
  }

  @override
  void dispose() {
    pivxNamesChanges.removeListener(_changed);
    super.dispose();
  }

  void _changed() => unawaited(_load());

  Future<void> _load({bool announce = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final key = await pivxNamesPublicKey(_wallet);
      final balance = await _registrar.balance(key);
      if (!mounted) return;
      setState(() => _balance = balance);
      if (announce) {
        final amount = pivxNamesAmount(balance.balance, ref, _wallet);
        unawaited(
          showFloatingFlushBar(
            type: FlushBarType.info,
            message: l10n.pivxNamesBalanceUpdated(amount),
            context: context,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = l10n.pivxNamesLoadBalanceFailed(pivxNamesError(e)),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// What a withdrawal of [sats] pays out after the service fee (an
  /// estimate: PIVX.name works it out).
  BigInt _net(BigInt sats, double feePercent) {
    final fee = Decimal.parse(feePercent.toString());
    final net =
        Decimal.fromBigInt(sats) *
        (Decimal.one -
            (fee / Decimal.fromInt(100)).toDecimal(
              scaleOnInfinitePrecision: 8,
            ));
    return net.floor().toBigInt();
  }

  Future<void> _withdraw() async {
    final balance = _balance;
    final address = _address;
    if (balance == null || address == null) return;
    final wallet = _wallet;
    final net = _net(balance.balance, balance.feePercent);
    final ok = await pivxNamesConfirm(
      context,
      title: l10n.pivxNamesWithdraw,
      message: l10n.pivxNamesWithdrawConfirm(
        pivxNamesAmount(balance.balance, ref, wallet),
        pivxAddressTitle(widget.walletId, address),
        pivxNamesAmount(net, ref, wallet),
        _fee(balance.feePercent),
      ),
      action: l10n.pivxNamesWithdraw,
    );
    if (!ok || !mounted) return;
    Exception? error;
    final done = await showLoading<bool>(
      context: context,
      message: l10n.pivxNamesAskingPayout,
      onException: (e) => error = e,
      whileFutureAlt: () async {
        final identity = await wallet.namesIdentity();
        final nonce = pivxNamesNonce();
        final signature = await identity.sign(
          pivxNamesWithdrawMessage(
            marker: _registrar.service.marker,
            pubkey: identity.publicKey,
            address: address,
            amountSats: balance.balance,
            nonce: nonce,
          ),
        );
        await _registrar.withdraw(
          pubkey: identity.publicKey,
          address: address,
          amount: balance.balance,
          nonce: nonce,
          signature: signature,
        );
        return true;
      },
    );
    if (!mounted) return;
    if (done != true) {
      await showPivxNamesError(
        context,
        error ?? l10n.pivxNamesWithdrawalFailedText,
        title: l10n.pivxNamesWithdrawalFailed,
      );
      return;
    }
    unawaited(
      showFloatingFlushBar(
        type: FlushBarType.success,
        message: l10n.pivxNamesWithdrawDone(pivxNamesAmount(net, ref, wallet)),
        context: context,
      ),
    );
    await _load();
  }

  static String _fee(double fee) =>
      fee == fee.roundToDouble() ? "${fee.toInt()}" : "$fee";

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final balance = _balance;
    // A balance under the minimum stays until more comes in: PIVX.name
    // refuses to pay it out.
    final belowMinimum =
        balance != null &&
        balance.balance > BigInt.zero &&
        balance.balance < balance.minWithdrawal;
    final canWithdraw =
        balance != null && balance.balance > BigInt.zero && !belowMinimum;
    final net = balance == null
        ? null
        : pivxNamesAmount(
            _net(balance.balance, balance.feePercent),
            ref,
            wallet,
          );
    final minimum = belowMinimum
        ? pivxNamesAmount(balance.minWithdrawal, ref, wallet, exact: true)
        : null;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PivxNamesAppBar(
          walletId: widget.walletId,
          title: l10n.pivxNamesMyBalance,
          section: PivxNamesSection.balance,
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.pivxNamesYourBalance,
                                    style: secondary,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    balance != null
                                        ? pivxNamesAmount(
                                            balance.balance,
                                            ref,
                                            wallet,
                                          )
                                        : _error != null
                                        ? l10n.commonUnavailable
                                        : "…",
                                    style: STextStyles.pageTitleH1(context),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: l10n.commonRefresh,
                              onPressed: _loading
                                  ? null
                                  : () => _load(announce: true),
                              icon: _loading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      Icons.refresh_rounded,
                                      color: colors.accentColorBlue,
                                    ),
                            ),
                          ],
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          style: STextStyles.w500_12(context)
                              .copyWith(color: colors.textError),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        l10n.pivxNamesBalanceExplained,
                        style: STextStyles.itemSubtitle(context),
                      ),
                      const SizedBox(height: 20),
                      Opacity(
                        opacity: canWithdraw ? 1 : 0.45,
                        child: IgnorePointer(
                          ignoring: !canWithdraw,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                l10n.pivxNamesWithdrawTo,
                                style: STextStyles.smallMed12(context),
                              ),
                              const SizedBox(height: 8),
                              PivxOwnAddressField(
                                walletId: widget.walletId,
                                value: _address,
                                shield: true,
                                placeholder: l10n.pivxNamesChooseAddress,
                                onChanged: (a) => setState(() => _address = a),
                              ),
                              if (canWithdraw) ...[
                                const SizedBox(height: 10),
                                Text(
                                  l10n.pivxNamesYouGetAbout(
                                    net!,
                                    _fee(balance.feePercent),
                                  ),
                                  style: secondary,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (belowMinimum) ...[
                        const SizedBox(height: 10),
                        Text(
                          l10n.pivxNamesMinimumWithdrawal(minimum!),
                          style: secondary,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: PrimaryButton(
                  label: l10n.pivxNamesWithdraw,
                  enabled: canWithdraw && _address != null && !_loading,
                  onPressed: _withdraw,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
