import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/locale_provider.dart';
import '../../providers/global/prefs_provider.dart';
import '../../providers/global/price_provider.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/assets.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/background.dart';
import '../../widgets/center_or_scroll.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/desktop_page_column.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/pivx_memo_field.dart';
import '../../widgets/stack_text_field.dart';
import '../send_view/confirm_transaction_view.dart';
import '../send_view/sub_widgets/building_transaction_dialog.dart';
import '../send_view/sub_widgets/pivx_funding_card.dart';
import '../send_view/sub_widgets/pivx_name_lookup.dart';
import 'pivx_donation.dart';
import 'pivx_donation_controls.dart';
import 'pivx_donation_stage.dart';

/// "Fuel PIVXie": pick a donation size on a slider and watch PIVXie get
/// the caffeine, pick the balance (the Shielded switch) and the coins, add
/// a cheers message, slide to brew. Paid to [kPivxDonationName].
class PivxDonationView extends ConsumerStatefulWidget {
  const PivxDonationView({super.key, required this.walletId});

  static const routeName = "/pivxDonation";

  final String walletId;

  @override
  ConsumerState<PivxDonationView> createState() => _PivxDonationViewState();
}

/// What the stage shows.
typedef _Look = ({String art, PivxDonationTier mood, PivxDonationEgg? egg});

class _PivxDonationViewState extends ConsumerState<PivxDonationView> {
  /// In [PivxDonationTier.values]: the fixed tiers, then the custom brew.
  int _index = PivxDonationTier.cyberMug.index;
  late PivxFunding _funding;

  /// Whether the balance or the coins were picked: the default no longer
  /// follows the price.
  bool _fundingChosen = false;

  /// PIVX in US dollars; null while [_priceLoading] or when unknown.
  Decimal? _price;
  bool _priceLoading = true;

  final _custom = TextEditingController();
  final _customFocus = FocusNode();
  bool _customInPiv = false;

  final _message = TextEditingController();
  final _messageFocus = FocusNode();

  bool _brewing = false;

  /// After a donation: the stage that thanks for it.
  _Look? _thanks;

  PivxDonationTier get _tier => PivxDonationTier.values[_index];

  @override
  void initState() {
    super.initState();
    final price = _appUsdPrice();
    _funding = _defaultFunding(
      price == null
          ? null
          : pivxDonationPiv(Decimal.fromInt(_tier.usd!), price),
    );
    unawaited(_loadPrice());
    // Opened once: the More menu stops pointing here.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(prefsChangeNotifierProvider).donationSeen = true,
    );
  }

  @override
  void dispose() {
    _custom.dispose();
    _customFocus.dispose();
    _message.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  /// The shielded balance when it pays [piv], else the transparent one
  /// when that does; else (or with [piv] unknown) whichever has coins,
  /// shielded first.
  PivxFunding _defaultFunding(Decimal? piv) {
    final wallet = ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;
    final shield = ref.read(pWalletBalanceSecondary(widget.walletId)).spendable;
    final transparent = ref.read(pWalletBalance(widget.walletId)).spendable;
    final want = piv == null
        ? null
        : Amount.fromDecimal(
            piv,
            fractionDigits: wallet.cryptoCurrency.fractionDigits,
          );
    bool pays(Amount balance) =>
        want == null ? balance > Amount.zero : balance >= want;
    final fromShield =
        wallet.supportsShield &&
        (pays(shield) || (!pays(transparent) && shield > Amount.zero));
    return (fromShield: fromShield, coins: const {}, changeAddress: null);
  }

  /// The price the app already has, when its currency is the dollar.
  Decimal? _appUsdPrice() {
    if (ref.read(prefsChangeNotifierProvider).currency != "USD") return null;
    final price = ref
        .read(priceAnd24hChangeNotifierProvider)
        .getPrice(ref.read(pWalletCoin(widget.walletId)))
        ?.value;
    return price == null || price <= Decimal.zero ? null : price;
  }

  Future<void> _loadPrice() async {
    final price = _appUsdPrice() ?? await pivxUsdPrice();
    if (!mounted) return;
    setState(() {
      _price = price;
      _priceLoading = false;
      if (price == null) _customInPiv = true;
      // The price may say the default balance can't pay.
      if (!_fundingChosen) _funding = _defaultFunding(_value.piv);
    });
  }

  /// The custom amount as typed, when it is one.
  Decimal? get _typed {
    final value = Decimal.tryParse(_custom.text.trim().replaceAll(",", "."));
    return value == null || value <= Decimal.zero ? null : value;
  }

  /// The donation in dollars and in PIV, each null where unknown.
  ({Decimal? usd, Decimal? piv}) get _value {
    final price = _price;
    final tier = _tier;
    if (!tier.isCustom) {
      final usd = Decimal.fromInt(tier.usd!);
      return (
        usd: usd,
        piv: price == null ? null : pivxDonationPiv(usd, price),
      );
    }
    final typed = _typed;
    if (typed == null) return (usd: null, piv: null);
    if (_customInPiv) {
      return (usd: price == null ? null : typed * price, piv: typed);
    }
    return (
      usd: typed,
      piv: price == null ? null : pivxDonationPiv(typed, price),
    );
  }

  _Look _look(({Decimal? usd, Decimal? piv}) value) {
    final tier = _tier;
    final usd = value.usd;
    final egg = tier.isCustom && usd != null ? PivxDonationEgg.of(usd) : null;
    final mood = !tier.isCustom
        ? tier
        : egg == PivxDonationEgg.madman
        // Holding its own mug, next to the giant one.
        ? PivxDonationTier.cyberMug
        : usd != null
        ? PivxDonationTier.artFor(usd)
        // The alchemist with the siphon, until there is an amount.
        : PivxDonationTier.zeroKnowledgeNitro;
    return (art: mood.art(shielded: _funding.fromShield), mood: mood, egg: egg);
  }

  void _setShield(bool shield) {
    if (shield == _funding.fromShield) return;
    HapticFeedback.selectionClick();
    setState(() {
      _fundingChosen = true;
      _funding = (fromShield: shield, coins: const {}, changeAddress: null);
    });
  }

  /// Switches the custom amount between dollars and PIV, converting what
  /// is typed.
  void _toggleCustomUnit() {
    final value = _value;
    setState(() {
      _customInPiv = !_customInPiv;
      final converted = _customInPiv ? value.piv : value.usd;
      final text = converted == null
          ? ""
          : _customInPiv
          ? converted.toString()
          : converted.round(scale: 2).toString();
      _custom.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
  }

  Future<void> _brew() async {
    if (_brewing) return;
    _brewing = true;
    try {
      FocusScope.of(context).unfocus();
      final wallet =
          ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;
      final coin = wallet.cryptoCurrency;
      final tier = _tier;
      final value = _value;
      final piv = value.piv;
      if (piv == null) return;
      final look = _look(value);
      final funding = _funding;
      final memo = pivxDonationMemo(
        tier: tier,
        usd: value.usd,
        message: _message.text,
      );

      // The name is looked up and proven like one typed on the send
      // screen, and checked again right before broadcasting.
      final name = await lookUpPivxNameForSend(
        context: context,
        coin: coin,
        name: kPivxDonationName,
        contacts: const [],
      );
      if (name == null || !mounted) return;

      final txData = await showBuildingTransaction<TxData>(
        context: context,
        coin: coin,
        build: () => preparePivxDonation(
          wallet,
          address: name.address,
          amount: Amount.fromDecimal(piv, fractionDigits: coin.fractionDigits),
          memo: memo,
          note: l10n.donateNote(tier.title),
          funding: funding,
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
              pivxName: name,
              onSuccess: () {},
              onSuccessInsteadOfRouteOnSuccess: () {
                navigator.popUntil(
                  ModalRoute.withName(PivxDonationView.routeName),
                );
                if (mounted) {
                  setState(() {
                    _thanks = look;
                    _message.clear();
                  });
                }
              },
            ),
          ),
          settings: const RouteSettings(name: ConfirmTransactionView.routeName),
        ),
      );
    } finally {
      _brewing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = ref.watch(pWallets).getWallet(widget.walletId) as PivxWallet;
    final palette = PivxDonationPalette.of(shielded: _funding.fromShield);
    final thanks = _thanks;
    return Background(
      child: AppScaffold(
        backgroundColor: colors.background,
        maxBodyWidth: ScreenFit.panesOrColumn(context),
        appBar: PageAppBar(
          // Shares the bar with the Shield switch: on a small phone a long
          // translation shrinks a little instead of losing its end.
          title: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              l10n.donateTitle,
              style: Util.isDesktop
                  ? STextStyles.desktopH3(context)
                  : STextStyles.navBarTitle(context),
            ),
          ),
          actions: [
            if (wallet.supportsShield && thanks == null)
              _ShieldSwitch(
                value: _funding.fromShield,
                onChanged: _setShield,
                palette: palette,
              ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: ScreenFit.sideBySide(context)
                    ? ScreenFit.panesWidth
                    : 560,
              ),
              child: thanks == null
                  ? _form(context, wallet, palette)
                  : _thanked(context, thanks),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(
    BuildContext context,
    PivxWallet wallet,
    PivxDonationPalette palette,
  ) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final coin = wallet.cryptoCurrency;
    final locale = ref.watch(
      localeServiceChangeNotifierProvider.select((value) => value.locale),
    );
    final tier = _tier;
    final value = _value;
    final look = _look(value);
    final amount = value.piv == null
        ? null
        : Amount.fromDecimal(value.piv!, fractionDigits: coin.fractionDigits);

    final fromShield = _funding.fromShield;
    final shield = ref
        .watch(pWalletBalanceSecondary(widget.walletId))
        .spendable;
    final transparent = ref.watch(pWalletBalance(widget.walletId)).spendable;
    final balance = fromShield ? shield : transparent;
    final other = fromShield ? transparent : shield;
    final short = amount != null && amount > balance;
    final otherPays =
        amount != null &&
        short &&
        amount <= other &&
        (fromShield || wallet.supportsShield);

    final title = [
      if (value.usd != null && (!tier.isCustom || !_customInPiv))
        pivxDonationUsdText(value.usd!, locale),
      "${tier.title} ${tier.emoji}",
    ].join(" • ");
    final pivLine = value.piv == null
        ? null
        : tier.isCustom && _customInPiv
        ? [
            pivxDonationPivText(value.piv!, coin.ticker, locale),
            if (value.usd != null)
              "≈ ${pivxDonationUsdText(value.usd!.round(scale: 2), locale)}",
          ].join(" ")
        : "≈ ${pivxDonationPivText(value.piv!, coin.ticker, locale)}";
    final description = look.egg?.text ?? tier.description;

    String? priceNote;
    if (!tier.isCustom && _price == null) {
      priceNote = _priceLoading ? l10n.donatePriceLoading : l10n.donateNoPrice;
    }

    final subtle = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);

    final about = <Widget>[
      PivxDonationStage(
        art: look.art,
        mood: look.mood,
        shielded: fromShield,
        egg: look.egg,
        height: _stageHeight(context),
      ),
      const SizedBox(height: 14),
      Text(
        tier.mascot.toUpperCase(),
        textAlign: TextAlign.center,
        style: subtle.copyWith(letterSpacing: 1.2),
      ),
      const SizedBox(height: 4),
      Text(
        title,
        textAlign: TextAlign.center,
        style: STextStyles.pageTitleH2(context),
      ),
      if (pivLine != null) ...[
        const SizedBox(height: 2),
        Text(
          pivLine,
          textAlign: TextAlign.center,
          style: STextStyles.w500_14(context)
              .copyWith(color: colors.textSubtitle1),
        ),
      ],
      const SizedBox(height: 8),
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            description,
            key: ValueKey(description),
            textAlign: TextAlign.center,
            style: STextStyles.itemSubtitle(context),
          ),
        ),
      ),
    ];
    final controls = <Widget>[
      PivxDonationTierSlider(
        labels: [
          for (final t in PivxDonationTier.fixed)
            pivxDonationUsdText(Decimal.fromInt(t.usd!), locale),
          l10n.donateCustom,
        ],
        index: _index,
        palette: palette,
        semanticLabel: l10n.donateSize,
        onChanged: (i) => setState(() => _index = i),
      ),
      if (priceNote != null) ...[
        const SizedBox(height: 12),
        Text(priceNote, textAlign: TextAlign.center, style: subtle),
      ],
      if (tier.isCustom) ...[
        const SizedBox(height: 16),
        _customField(context, coin.ticker),
      ],
      const SizedBox(height: 20),
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
      if (short) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                fromShield
                    ? l10n.donateNotEnoughShielded
                    : l10n.donateNotEnoughTransparent,
                style: STextStyles.errorSmall(context),
              ),
            ),
            if (otherPays)
              CustomTextButton(
                text: fromShield
                    ? l10n.donateUseTransparent
                    : l10n.donateUseShielded,
                onTap: () => _setShield(!fromShield),
              ),
          ],
        ),
      ],
      const SizedBox(height: 20),
      Text(l10n.donateCheers, style: STextStyles.smallMed12(context)),
      const SizedBox(height: 8),
      PivxMemoField(
        key: const ValueKey("donation-cheers"),
        controller: _message,
        focusNode: _messageFocus,
        maxBytes: kPivxDonationMessageBytes,
        hint: l10n.donateCheersHint,
      ),
      const SizedBox(height: 6),
      Text(l10n.donateCheersNote, style: subtle),
    ];
    final slide = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        children: [
          PivxSlideToConfirm(
            label: l10n.donateSlide,
            palette: palette,
            enabled: amount != null && !short,
            onConfirmed: _brew,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.donateTo(kPivxDonationName),
            textAlign: TextAlign.center,
            style: subtle,
          ),
        ],
      ),
    );

    if (ScreenFit.sideBySide(context)) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 4,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 16),
              children: about,
            ),
          ),
          Expanded(
            flex: 5,
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(8, 4, 16, 16),
                    children: controls,
                  ),
                ),
                slide,
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [...about, const SizedBox(height: 20), ...controls],
          ),
        ),
        slide,
      ],
    );
  }

  /// Leaves room for the lines under the stage on a phone on its side.
  double _stageHeight(BuildContext context) => ScreenFit.sideBySide(context)
      ? (ScreenFit.bodyHeight(context) - 150).clamp(150.0, 250.0)
      : 250;

  Widget _customField(BuildContext context, String ticker) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final canSwitch = _price != null;
    final unit = _customInPiv ? ticker : "USD";
    return TextField(
      // Kept by key: the lines above it come and go as the amount is typed,
      // and a rebuilt field would lose the focus.
      key: const ValueKey("donation-amount"),
      controller: _custom,
      focusNode: _customFocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [_AmountFormatter(decimals: _customInPiv ? 8 : 2)],
      style: STextStyles.field(context),
      onChanged: (_) => setState(() {}),
      decoration:
          standardInputDecoration(
            l10n.commonAmount,
            _customFocus,
            context,
          ).copyWith(
            prefixText: _customInPiv ? null : "\$ ",
            suffixIcon: Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: canSwitch
                  ? TextButton.icon(
                      onPressed: _toggleCustomUnit,
                      icon: Icon(
                        Icons.swap_horiz_rounded,
                        size: 18,
                        color: colors.accentColorBlue,
                      ),
                      label: Text(
                        unit,
                        style: STextStyles.w600_14(context)
                            .copyWith(color: colors.accentColorBlue),
                      ),
                    )
                  : Center(
                      widthFactor: 1,
                      child: Text(unit, style: STextStyles.w600_14(context)),
                    ),
            ),
          ),
    );
  }

  Widget _thanked(BuildContext context, _Look look) {
    final stage = PivxDonationStage(
      art: Assets.donation.thanks(shielded: _funding.fromShield),
      mood: look.mood,
      shielded: _funding.fromShield,
      celebrating: true,
      height: _stageHeight(context),
    );
    final text = <Widget>[
      Text(
        l10n.donateThanksTitle,
        textAlign: TextAlign.center,
        style: STextStyles.pageTitleH1(context),
      ),
      const SizedBox(height: 8),
      Text(
        l10n.donateThanksText(kPivxDonationName),
        textAlign: TextAlign.center,
        style: STextStyles.itemSubtitle(context),
      ),
    ];
    final buttons = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: SecondaryButton(
              label: l10n.donateAgain,
              onPressed: () => setState(() => _thanks = null),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryButton(
              label: l10n.commonDone,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );

    if (ScreenFit.sideBySide(context)) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 4,
            child: CenterOrScroll(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 16),
                child: stage,
              ),
            ),
          ),
          Expanded(
            flex: 5,
            child: Column(
              children: [
                Expanded(
                  child: CenterOrScroll(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: text,
                      ),
                    ),
                  ),
                ),
                buttons,
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [stage, const SizedBox(height: 20), ...text],
          ),
        ),
        buttons,
      ],
    );
  }
}

/// The app bar's Shielded switch: pays from the shielded balance (and
/// shows the hooded PIVXie) or from the transparent one.
class _ShieldSwitch extends StatelessWidget {
  const _ShieldSwitch({
    required this.value,
    required this.onChanged,
    required this.palette,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final PivxDonationPalette palette;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: MergeSemantics(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  value ? Icons.shield_rounded : Icons.shield_outlined,
                  size: 16,
                  color: value ? colors.accentColorBlue : colors.textSubtitle1,
                ),
                const SizedBox(width: 4),
                Text(
                  l10n.donateShielded,
                  style: STextStyles.w500_12(context).copyWith(
                    color: value ? colors.textDark : colors.textSubtitle1,
                  ),
                ),
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: value,
                    onChanged: onChanged,
                    activeTrackColor: palette.glow,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Up to twelve whole digits and [decimals] decimals, with "." or ",".
class _AmountFormatter extends TextInputFormatter {
  _AmountFormatter({required int decimals})
    : _pattern = RegExp("^\\d{0,12}([.,]\\d{0,$decimals})?\$");

  final RegExp _pattern;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => _pattern.hasMatch(newValue.text) ? newValue : oldValue;
}
