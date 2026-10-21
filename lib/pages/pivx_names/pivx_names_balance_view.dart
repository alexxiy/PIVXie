import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
            message: "Balance updated: $amount",
            context: context,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = "Couldn't load the balance. ${pivxNamesError(e)}",
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
      title: "Withdraw",
      message:
          "Withdraw ${pivxNamesAmount(balance.balance, ref, wallet)} to "
          "${pivxAddressTitle(widget.walletId, address)}? You'll get about "
          "${pivxNamesAmount(net, ref, wallet)} after the service fee "
          "(${_fee(balance.feePercent)}%).",
      action: "Withdraw",
    );
    if (!ok || !mounted) return;
    Exception? error;
    final done = await showLoading<bool>(
      context: context,
      message: "Asking PIVX.name to pay out",
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
        error ?? "The withdrawal failed",
        title: "Withdrawal failed",
      );
      return;
    }
    unawaited(
      showFloatingFlushBar(
        type: FlushBarType.success,
        message:
            "Done! About ${pivxNamesAmount(net, ref, wallet)} is on its way to "
            "your wallet.",
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
          title: "My Balance",
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
                                  Text("Your balance", style: secondary),
                                  const SizedBox(height: 6),
                                  Text(
                                    balance != null
                                        ? pivxNamesAmount(
                                            balance.balance,
                                            ref,
                                            wallet,
                                          )
                                        : _error != null
                                        ? "Unavailable"
                                        : "…",
                                    style: STextStyles.pageTitleH1(context),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: "Refresh",
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
                        "Payments PIVX.name couldn't use come back here, and "
                        "so does the price of a name you sell. Withdraw them "
                        "to your wallet whenever you like.",
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
                                "Withdraw to",
                                style: STextStyles.smallMed12(context),
                              ),
                              const SizedBox(height: 8),
                              PivxOwnAddressField(
                                walletId: widget.walletId,
                                value: _address,
                                shield: true,
                                placeholder: "Choose an address",
                                onChanged: (a) => setState(() => _address = a),
                              ),
                              if (canWithdraw) ...[
                                const SizedBox(height: 10),
                                Text(
                                  "You'll get about $net after the service "
                                  "fee (${_fee(balance.feePercent)}%).",
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
                          "The minimum withdrawal is $minimum. Your balance "
                          "stays here until it reaches that.",
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
                  label: "Withdraw",
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
