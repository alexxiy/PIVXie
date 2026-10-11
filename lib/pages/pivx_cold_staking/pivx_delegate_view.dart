import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../notifications/show_flush_bar.dart';
import '../../providers/global/barcode_scanner_provider.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/icon_buttons.dart';
import '../../widgets/icon_widgets/clipboard_icon.dart';
import '../../widgets/icon_widgets/qrcode_icon.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_text_field.dart';
import '../pivx_governance/pivx_governance_widgets.dart';
import '../pivx_masternodes/pivx_masternodes_view.dart';
import '../send_view/confirm_transaction_view.dart';
import '../send_view/sub_widgets/pivx_funding_card.dart';
import 'pivx_cold_staking_view.dart';

const _kMasternodeSpaceUrl = "https://masternode.space";

/// Delegate coins to a staker: how to get a staker address
/// (masternode.space or your own node), then the staker and the amount.
class PivxDelegateView extends ConsumerStatefulWidget {
  const PivxDelegateView({super.key, required this.walletId});

  static const routeName = "/pivxDelegate";

  final String walletId;

  @override
  ConsumerState<PivxDelegateView> createState() => _PivxDelegateViewState();
}

class _PivxDelegateViewState extends ConsumerState<PivxDelegateView> {
  final _staker = TextEditingController();
  final _stakerFocus = FocusNode();
  final _amount = TextEditingController();
  final _amountFocus = FocusNode();

  String? _owner;

  /// Owners of the current delegations (already whitelisted).
  Set<String> _owners = const {};

  PivxFunding _funding = kPivxAutoFunding;
  bool _subtractFee = false;

  /// Whether this wallet already delegates (the guide starts folded).
  bool _delegating = false;
  bool _showGuide = true;
  bool _showVps = false;

  /// Show errors only for fields the user touched (or after "Delegate").
  final _touched = <TextEditingController>{};

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  @override
  void initState() {
    super.initState();
    _staker.addListener(() {
      _touched.add(_staker);
      setState(() {});
    });
    _amount.addListener(() {
      _touched.add(_amount);
      setState(() {});
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final wallet = _wallet;
    await wallet.loadMasternodeNetwork();
    final owner = await wallet.coldStakeOwnerAddress();
    final delegations = await wallet.loadDelegations();
    final staker = wallet.currentStaker(delegations);
    if (!mounted) return;
    setState(() {
      _owner = owner;
      _owners = {for (final d in delegations) d.owner};
      _delegating = delegations.isNotEmpty;
      _showGuide = delegations.isEmpty;
      if (staker != null && _staker.text.isEmpty) {
        _staker.text = staker;
        _touched.remove(_staker);
      }
    });
  }

  @override
  void dispose() {
    _staker.dispose();
    _stakerFocus.dispose();
    _amount.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  /// What the chosen funding can pay.
  Amount get _available {
    final info = _wallet.info;
    if (_funding.coins.isNotEmpty) {
      return Amount(
        rawValue: _funding.coins.fold(
          BigInt.zero,
          (p, u) => p + BigInt.from(u.value),
        ),
        fractionDigits: _wallet.cryptoCurrency.fractionDigits,
      );
    }
    return _funding.fromShield
        ? info.cachedBalanceSecondary.spendable
        : info.cachedBalance.spendable;
  }

  Amount? get _amountValue {
    final d = Decimal.tryParse(_amount.text.trim().replaceAll(",", "."));
    if (d == null || d <= Decimal.zero) return null;
    return d.toAmount(fractionDigits: _wallet.cryptoCurrency.fractionDigits);
  }

  Map<TextEditingController, String?> get _errors => {
    _staker: _wallet.stakerAddressError(_staker.text.trim()),
    _amount: _wallet.delegationAmountError(_amountValue, available: _available),
  };

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) _staker.text = text;
  }

  Future<void> _scan() async {
    if (FocusScope.of(context).hasFocus) {
      FocusScope.of(context).unfocus();
      await Future<void>.delayed(const Duration(milliseconds: 75));
    }
    if (!mounted) return;
    final result = await ref.read(pBarcodeScanner).scan(context: context);
    final raw = result.rawContent?.trim();
    if (raw == null || raw.isEmpty) return;
    // A bare address, or a "pivx:<address>?..." link.
    var text = raw.split("\n").first;
    if (text.contains(":")) text = text.substring(text.indexOf(":") + 1);
    _staker.text = text.split("?").first.trim();
  }

  Future<void> _delegate() async {
    final errors = _errors;
    if (errors.values.any((e) => e != null)) {
      setState(() => _touched.addAll(errors.keys));
      return;
    }
    final wallet = _wallet;
    Exception? error;
    final txData = await showLoading<TxData>(
      whileFutureAlt: () => wallet.prepareDelegation(
        staker: _staker.text.trim(),
        amount: _amountValue!,
        owner: _owner!,
        funding: _funding,
        subtractFee: _subtractFee,
      ),
      context: context,
      message: "Preparing the delegation",
      onException: (e) => error = e,
    );
    if (!mounted) return;
    if (txData == null) {
      await showFloatingFlushBar(
        type: FlushBarType.warning,
        message:
            error?.toString().replaceFirst("Exception: ", "") ??
            "Could not prepare the delegation",
        context: context,
        duration: const Duration(seconds: 5),
      );
      return;
    }
    await Navigator.of(context).push(
      RouteGenerator.getRoute<void>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) => ConfirmTransactionView(
          txData: txData,
          walletId: widget.walletId,
          onSuccess: () {},
          onSuccessInsteadOfRouteOnSuccess: () {
            if (mounted) {
              Navigator.of(context)
                  .popUntil(ModalRoute.withName(PivxColdStakingView.routeName));
            }
          },
        ),
        settings: const RouteSettings(name: ConfirmTransactionView.routeName),
      ),
    );
  }

  /// A text field outlined in red, with its error (or [helper]) under it.
  Widget _field({
    required TextEditingController controller,
    required FocusNode focus,
    required String hint,
    String? helper,
    TextInputType? keyboardType,
    List<TextInputFormatter>? formatters,
    Widget? suffix,
    bool enabled = true,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final error = _touched.contains(controller) ? _errors[controller] : null;
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
            enabled: enabled,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: keyboardType,
            inputFormatters: formatters,
            style: STextStyles.field(context),
            decoration: standardInputDecoration(hint, focus, context).copyWith(
              enabledBorder: border,
              focusedBorder: border,
              suffixIcon: suffix,
            ),
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 4, top: 4),
            child: Text(
              note,
              style: STextStyles.label(context).copyWith(
                color: error != null ? colors.textError : colors.textSubtitle1,
              ),
            ),
          ),
      ],
    );
  }

  Widget _step(int n, String text) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.accentColorBlue.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Text(
              "$n",
              style: STextStyles.w600_12(context)
                  .copyWith(color: colors.accentColorBlue),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: STextStyles.itemSubtitle(context))),
        ],
      ),
    );
  }

  Widget _code(String code) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: colors.textFieldDefaultBG,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              code,
              style: STextStyles.w500_12(context)
                  .copyWith(fontFamily: "monospace", color: colors.textDark),
            ),
          ),
          IconCopyButton(data: code),
        ],
      ),
    );
  }

  Widget _guide() {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final owner = _owner ?? "…";
    final cli = wallet.pivxCliCommand;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RoundedWhiteContainer(
          borderColor: colors.accentColorBlue,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      "Easiest: masternode.space",
                      style: STextStyles.w600_14(context),
                    ),
                  ),
                  PivxPill(
                    text: "No server needed",
                    color: colors.accentColorGreen,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                "masternode.space runs the staker for you. No server to "
                "rent and no technical setup.",
                style: STextStyles.itemSubtitle(context),
              ),
              const SizedBox(height: 12),
              _step(
                1,
                "On masternode.space, open the main menu, choose PIVX Cold "
                "Staking, turn it on and copy your staker address.",
              ),
              _step(2, "Paste the staker address below and delegate."),
              _step(
                3,
                "Back on masternode.space, enter your owner address so the "
                "staker accepts your coins:",
              ),
              PivxCopyRow(title: "Your owner address", value: owner),
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
        const SizedBox(height: 8),
        RoundedWhiteContainer(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showVps = !_showVps),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          "Or use your own PIVX node (VPS)",
                          style: STextStyles.w600_14(context),
                        ),
                      ),
                      Icon(
                        _showVps
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: colors.textSubtitle1,
                      ),
                    ],
                  ),
                ),
              ),
              if (_showVps)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        "On a server running PIVX Core that stays online, "
                        "create a staker address:",
                        style: STextStyles.itemSubtitle(context),
                      ),
                      _code("$cli getnewstakingaddress \"PIVXie\""),
                      Text(
                        "Whitelist your owner address so the node stakes "
                        "your coins:",
                        style: STextStyles.itemSubtitle(context),
                      ),
                      _code("$cli delegatoradd $owner"),
                      Text(
                        "If the node's wallet is encrypted, unlock it for "
                        "staking only:",
                        style: STextStyles.itemSubtitle(context),
                      ),
                      _code("$cli walletpassphrase \"your passphrase\" 0 true"),
                      Text(
                        "Staking is on by default; \"$cli getstakingstatus\" "
                        "shows whether the node is staking.",
                        style: STextStyles.itemSubtitle(context),
                      ),
                    ],
                  ),
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
    final available = _available;
    final startsIn = pivxDuration(
      wallet.coldStakeMinDepth * coin.targetBlockTimeSeconds,
    );

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            _delegating ? "Delegate more" : "Start cold staking",
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
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            "Get a staker address",
                            style: STextStyles.w600_14(context),
                          ),
                        ),
                        if (_delegating)
                          CustomTextButton(
                            text: _showGuide ? "Hide" : "Show how",
                            onTap: () =>
                                setState(() => _showGuide = !_showGuide),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_showGuide) ...[_guide(), const SizedBox(height: 8)],
                    const SizedBox(height: 12),
                    Text("Staker address", style: label),
                    const SizedBox(height: 8),
                    _field(
                      controller: _staker,
                      focus: _stakerFocus,
                      hint: "Starts with \"${wallet.stakingAddressLetter}\"",
                      suffix: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: "Paste",
                            onPressed: _paste,
                            icon: const ClipboardIcon(),
                          ),
                          IconButton(
                            tooltip: "Scan QR code",
                            onPressed: _scan,
                            icon: const QrCodeIcon(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text("Owner address", style: label),
                    const SizedBox(height: 8),
                    PivxOwnAddressField(
                      walletId: widget.walletId,
                      value: _owner,
                      tags: {for (final o in _owners) o: "owns your delegations"},
                      onChanged: (a) => setState(() => _owner = a),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 12, top: 4),
                      child: Text(
                        _owners.isNotEmpty && !_owners.contains(_owner)
                            ? "A different owner than your current "
                                  "delegations: whitelist it on your staker "
                                  "too."
                            : "The coins stay at this address of your "
                                  "wallet. The staker can stake them but "
                                  "never spend them.",
                        style: STextStyles.label(context).copyWith(
                          color:
                              _owners.isNotEmpty && !_owners.contains(_owner)
                              ? colors.accentColorOrange
                              : colors.textSubtitle1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: Text("Amount", style: label)),
                        CustomTextButton(
                          text: "Max",
                          onTap: () => setState(() {
                            _subtractFee = true;
                            _amount.text = available.decimal.toString();
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _field(
                      controller: _amount,
                      focus: _amountFocus,
                      hint: "Amount (${coin.ticker})",
                      helper: "Available: ${fmt.format(available)}",
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      formatters: [
                        FilteringTextInputFormatter.allow(RegExp(r"[0-9.,]")),
                      ],
                    ),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => setState(() => _subtractFee = !_subtractFee),
                      child: Row(
                        children: [
                          Checkbox(
                            value: _subtractFee,
                            activeColor: colors.checkboxBGChecked,
                            checkColor: colors.checkboxIconChecked,
                            onChanged: (v) =>
                                setState(() => _subtractFee = v ?? false),
                          ),
                          Expanded(
                            child: Text(
                              "Subtract fee from amount",
                              style: STextStyles.w500_14(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    PivxFundingCard(
                      walletId: widget.walletId,
                      funding: _funding,
                      amount: _amountValue,
                      subtractFee: _subtractFee,
                      onChanged: (f) => setState(() {
                        _funding = f;
                        _touched.add(_amount);
                      }),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Delegated coins start staking after about $startsIn.",
                      style: secondary,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: PrimaryButton(
                  label: "Delegate",
                  enabled: _owner != null,
                  onPressed: _delegate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
