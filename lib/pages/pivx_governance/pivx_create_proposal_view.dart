import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_text_field.dart';
import '../pivx_masternodes/pivx_masternodes_view.dart';
import '../send_view/confirm_transaction_view.dart';
import '../send_view/sub_widgets/building_transaction_dialog.dart';
import '../send_view/sub_widgets/pivx_funding_card.dart';
import 'pivx_governance_view.dart';
import '../../widgets/desktop/desktop_page_column.dart';

/// Ask the network for funds: name, link, payee, amount per payout,
/// payouts and the first one. Publishing costs a 50 PIV fee (burnt);
/// once it has enough confirmations the wallet submits the proposal.
class PivxCreateProposalView extends ConsumerStatefulWidget {
  const PivxCreateProposalView({super.key, required this.walletId});

  static const routeName = "/pivxCreateProposal";

  final String walletId;

  @override
  ConsumerState<PivxCreateProposalView> createState() =>
      _PivxCreateProposalViewState();
}

class _PivxCreateProposalViewState
    extends ConsumerState<PivxCreateProposalView> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  final _url = TextEditingController(text: "https://");
  final _urlFocus = FocusNode();

  /// Where the payouts go: one of the wallet's addresses.
  String? _payee;
  PivxFunding _funding = kPivxAutoFunding;
  final _amount = TextEditingController();
  final _amountFocus = FocusNode();

  int _payments = 1;
  int? _start;
  List<int> _starts = const [];
  int _height = 0;

  /// Show errors only for fields the user touched (or after "Pay").
  final _touched = <TextEditingController>{};

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _url, _amount]) {
      c.addListener(() {
        _touched.add(c);
        setState(() {});
      });
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    final wallet = _wallet;
    final height = await wallet.chainHeight;
    final receive = await wallet.getCurrentReceivingAddress();
    if (!mounted) return;
    setState(() {
      _height = height;
      _starts = wallet.proposalStartSuperblocks(height);
      _start = _starts.firstOrNull;
      _payee ??= receive?.value;
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _amount]) {
      c.dispose();
    }
    for (final f in [_nameFocus, _urlFocus, _amountFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  Amount? get _amountValue {
    final d = Decimal.tryParse(_amount.text.trim().replaceAll(",", "."));
    if (d == null || d <= Decimal.zero) return null;
    return d.toAmount(fractionDigits: _wallet.cryptoCurrency.fractionDigits);
  }

  String? _error(TextEditingController c, String? error) =>
      _touched.contains(c) ? error : null;

  Map<TextEditingController, String?> get _errors {
    final wallet = _wallet;
    return {
      _name: wallet.proposalNameError(_name.text.trim()),
      _url: wallet.proposalUrlError(_url.text.trim()),
      _amount: wallet.proposalAmountError(_amountValue),
    };
  }

  Future<void> _pay() async {
    final errors = _errors;
    if (errors.values.any((e) => e != null) ||
        _start == null ||
        _payee == null) {
      setState(() => _touched.addAll(errors.keys));
      return;
    }
    final wallet = _wallet;
    final prepared =
        await showBuildingTransaction<(TxData, PivxPendingProposal)>(
          context: context,
          coin: wallet.cryptoCurrency,
          build: () => wallet.prepareProposal(
            name: _name.text.trim(),
            url: _url.text.trim(),
            payments: _payments,
            blockStart: _start!,
            paymentAddress: _payee!,
            amount: _amountValue!,
            funding: _funding,
          ),
        );
    if (!mounted || prepared == null) return;
    final (txData, proposal) = prepared;
    await Navigator.of(context).push(
      RouteGenerator.getRoute<void>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) => DesktopPageColumn(
          card: true,
          child: ConfirmTransactionView(
            txData: txData,
            walletId: widget.walletId,
            // Remembered before the fee goes out: were the app to stop
            // right after sending, the fee would be burnt with nothing
            // left to submit the proposal.
            beforeBroadcast: () =>
                wallet.addPendingProposal(proposal, txData.txid!),
            afterFailedBroadcast: () => wallet.forgetUnsentProposal(proposal),
            onSuccess: () {},
            onSuccessInsteadOfRouteOnSuccess: () {
              if (mounted) {
                Navigator.of(
                  context,
                ).popUntil(ModalRoute.withName(PivxGovernanceView.routeName));
              }
            },
          ),
        ),
        settings: const RouteSettings(name: ConfirmTransactionView.routeName),
      ),
    );
  }

  /// A text field outlined in red, with [error] under it, while invalid.
  Widget _field({
    required TextEditingController controller,
    required FocusNode focus,
    required String hint,
    String? helper,
    int? maxLength,
    bool plain = false,
    TextInputType? keyboardType,
    List<TextInputFormatter>? formatters,
    Widget? suffix,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final error = _error(controller, _errors[controller]);
    final border = error == null
        ? null
        : OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: colors.textError, width: 1.5),
          );
    final note = error ?? helper;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: TextField(
            controller: controller,
            focusNode: focus,
            autocorrect: !plain,
            enableSuggestions: !plain,
            keyboardType: keyboardType,
            inputFormatters: [
              if (maxLength != null)
                LengthLimitingTextInputFormatter(maxLength),
              ...?formatters,
            ],
            style: STextStyles.field(context),
            decoration: standardInputDecoration(hint, focus, context).copyWith(
              enabledBorder: border,
              focusedBorder: border,
              suffixIcon: suffix,
            ),
          ),
        ),
        if (note != null || maxLength != null)
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 4, top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    note ?? "",
                    style: STextStyles.label(context).copyWith(
                      color: error != null
                          ? colors.textError
                          : colors.textSubtitle1,
                    ),
                  ),
                ),
                if (maxLength != null)
                  Text(
                    "${controller.text.length}/$maxLength",
                    style: STextStyles.label(context),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final coin = wallet.cryptoCurrency;
    final fmt = ref.watch(pAmountFormatter(coin));
    final label = STextStyles.smallMed12(context);
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final amount = _amountValue;
    final fee = Amount(
      rawValue: BigInt.from(kPivxProposalFeeSats),
      fractionDigits: coin.fractionDigits,
    );
    final total = amount == null
        ? null
        : Amount(
            rawValue: amount.raw * BigInt.from(_payments),
            fractionDigits: coin.fractionDigits,
          );
    final balance = _funding.coins.isNotEmpty
        ? Amount(
            rawValue: _funding.coins.fold(
              BigInt.zero,
              (p, u) => p + BigInt.from(u.value),
            ),
            fractionDigits: coin.fractionDigits,
          )
        : _funding.fromShield
        ? wallet.info.cachedBalanceSecondary.spendable
        : wallet.info.cachedBalance.spendable;
    final enoughFunds = balance.raw > fee.raw;

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PageAppBar(
          title: Text(
            l10n.govCreateProposal,
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    RoundedWhiteContainer(
                      child: Text(
                        l10n.govCreateIntro(fmt.format(fee)),
                        style: secondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(l10n.govProposalName, style: label),
                    const SizedBox(height: 8),
                    _field(
                      controller: _name,
                      focus: _nameFocus,
                      hint: l10n.govProposalNameHint,
                      maxLength: kPivxProposalNameMax,
                    ),
                    const SizedBox(height: 12),
                    Text(l10n.govProposalLink, style: label),
                    const SizedBox(height: 8),
                    _field(
                      controller: _url,
                      focus: _urlFocus,
                      hint: "https://forum.pivx.org/…",
                      maxLength: kPivxProposalUrlMax,
                      plain: true,
                      keyboardType: TextInputType.url,
                    ),
                    const SizedBox(height: 12),
                    Text(l10n.govPayoutsGoTo, style: label),
                    const SizedBox(height: 8),
                    PivxOwnAddressField(
                      walletId: widget.walletId,
                      value: _payee,
                      onChanged: (a) => setState(() => _payee = a),
                    ),
                    const SizedBox(height: 12),
                    Text(l10n.govAmountPerPayout, style: label),
                    const SizedBox(height: 8),
                    _field(
                      controller: _amount,
                      focus: _amountFocus,
                      hint: l10n.govAmountTicker(coin.ticker),
                      helper: l10n.govAmountRange(
                        "${kPivxProposalMinSats ~/ 100000000}",
                        fmt.format(wallet.budgetPerSuperblock),
                      ),
                      plain: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      formatters: [
                        FilteringTextInputFormatter.allow(RegExp(r"[0-9.,]")),
                      ],
                    ),
                    const SizedBox(height: 16),
                    RoundedWhiteContainer(
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.govPayouts,
                                  style: STextStyles.w600_14(context),
                                ),
                                Text(
                                  l10n.govPayoutsUpTo(
                                    wallet.maxProposalPayments,
                                  ),
                                  style: secondary,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: _payments > 1
                                ? () => setState(() => _payments--)
                                : null,
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          Text(
                            "$_payments",
                            style: STextStyles.pageTitleH2(context),
                          ),
                          IconButton(
                            onPressed: _payments < wallet.maxProposalPayments
                                ? () => setState(() => _payments++)
                                : null,
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(l10n.govFirstPayout, style: label),
                    const SizedBox(height: 8),
                    if (_starts.isEmpty)
                      const Center(child: CircularProgressIndicator())
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final s in _starts)
                            ChoiceChip(
                              label: Text(
                                l10n.govBlockIn(
                                  s,
                                  pivxDuration(
                                    (s - _height) * coin.targetBlockTimeSeconds,
                                  ),
                                ),
                              ),
                              selected: _start == s,
                              showCheckmark: false,
                              selectedColor: colors.accentColorBlue.withValues(
                                alpha: 0.18,
                              ),
                              backgroundColor: colors.popupBG,
                              side: BorderSide(
                                color: _start == s
                                    ? colors.accentColorBlue
                                    : colors.textFieldDefaultBG,
                              ),
                              labelStyle: STextStyles.w600_12(context).copyWith(
                                color: _start == s
                                    ? colors.accentColorBlue
                                    : colors.textDark,
                              ),
                              onSelected: (_) => setState(() => _start = s),
                            ),
                        ],
                      ),
                    if (_starts.isNotEmpty &&
                        _starts.first !=
                            _height -
                                _height % wallet.budgetCycleBlocks +
                                wallet.budgetCycleBlocks) ...[
                      const SizedBox(height: 6),
                      Text(l10n.govPayoutTooClose, style: secondary),
                    ],
                    const SizedBox(height: 16),
                    PivxFundingCard(
                      walletId: widget.walletId,
                      funding: _funding,
                      amount: fee,
                      onChanged: (f) => setState(() => _funding = f),
                    ),
                    const SizedBox(height: 16),
                    RoundedWhiteContainer(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _summary(
                            l10n.govAskedInTotal,
                            total == null ? "—" : fmt.format(total),
                          ),
                          _summary(l10n.govFeeBurnt, fmt.format(fee)),
                          _summary(
                            _funding.coins.isNotEmpty
                                ? l10n.govSelectedCoins
                                : _funding.fromShield
                                ? l10n.balanceShielded
                                : l10n.balanceTransparent,
                            fmt.format(balance),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            l10n.govAfterFee(wallet.proposalFeeConfirmations),
                            style: secondary,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: PrimaryButton(
                  label: enoughFunds
                      ? l10n.govPayAndPublish(fmt.format(fee))
                      : l10n.govNotEnoughForFee(coin.ticker),
                  enabled: enoughFunds && _start != null,
                  onPressed: _pay,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summary(String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: STextStyles.w500_12(context).copyWith(
              color: Theme.of(context).extension<StackColors>()!.textSubtitle1,
            ),
          ),
        ),
        Text(value, style: STextStyles.w600_12(context)),
      ],
    ),
  );
}
