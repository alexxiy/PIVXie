import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:tuple/tuple.dart';

import '../../../db/isar/main_db.dart';
import '../../../models/isar/models/isar_models.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/amount/amount_formatter.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../wallets/wallet/impl/pivx_wallet.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/icon_widgets/x_icon.dart';
import '../../../widgets/middle_ellipsis_text.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/stack_text_field.dart';
import '../../../widgets/textfield_icon_button.dart';
import '../../coin_control/coin_control_view.dart';
import 'pivx_change_address_sheet.dart';

/// How a PIVX transaction is paid ([PivxFunding]): from the public or the
/// private balance, with which coins, and where the change goes.
class PivxFundingCard extends ConsumerWidget {
  const PivxFundingCard({
    super.key,
    required this.walletId,
    required this.funding,
    required this.onChanged,
    this.amount,
    this.subtractFee = false,
    this.allowShield = true,
  });

  final String walletId;
  final PivxFunding funding;
  final ValueChanged<PivxFunding> onChanged;

  /// What is being paid, for the coin control summary.
  final Amount? amount;
  final bool subtractFee;

  /// Whether the private balance can pay this transaction.
  final bool allowShield;

  Future<void> _chooseCoins(BuildContext context) async {
    final result = await Navigator.of(context).pushNamed(
      CoinControlView.routeName,
      arguments: Tuple5(
        walletId,
        CoinControlViewType.use,
        amount,
        funding.coins,
        (
          shieldNotes: funding.fromShield,
          sendAmount: amount,
          toShield: false,
          subtractFee: subtractFee,
        ),
      ),
    );
    if (result is Set<UTXO>) {
      onChanged((
        fromShield: funding.fromShield,
        coins: result,
        changeAddress: funding.changeAddress,
      ));
    }
  }

  Future<void> _chooseChange(BuildContext context, Pivx coin) async {
    final picked = await showModalBottomSheet<String>(
      backgroundColor: Colors.transparent,
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => PivxChangeAddressSheet(
        walletId: walletId,
        coin: coin,
        current: funding.changeAddress,
        shield: funding.fromShield,
      ),
    );
    if (picked != null) {
      onChanged((
        fromShield: funding.fromShield,
        coins: funding.coins,
        changeAddress: picked.isEmpty ? null : picked,
      ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = ref.watch(pWallets).getWallet(walletId) as PivxWallet;
    final coin = wallet.cryptoCurrency;
    final fmt = ref.watch(pAmountFormatter(coin));
    final public = ref.watch(pWalletBalance(walletId)).spendable;
    final private = ref.watch(pWalletBalanceSecondary(walletId)).spendable;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final coinsTotal = Amount(
      rawValue: funding.coins.fold(
        BigInt.zero,
        (p, u) => p + BigInt.from(u.value),
      ),
      fractionDigits: coin.fractionDigits,
    );
    final change = funding.changeAddress;

    Widget source(String label, bool shield, Amount balance) {
      final selected = funding.fromShield == shield;
      return Expanded(
        child: GestureDetector(
          onTap: selected
              ? null
              : () => onChanged((
                  fromShield: shield,
                  coins: const {},
                  changeAddress: null,
                )),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            decoration: BoxDecoration(
              color: selected
                  ? colors.accentColorBlue.withValues(alpha: 0.12)
                  : colors.textFieldDefaultBG,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? colors.accentColorBlue : Colors.transparent,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: STextStyles.w600_14(context).copyWith(
                    color: selected ? colors.accentColorBlue : colors.textDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(fmt.format(balance), style: secondary),
              ],
            ),
          ),
        ),
      );
    }

    Widget row(String title, String value, List<Widget> actions) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: STextStyles.w600_14(context)),
                const SizedBox(height: 2),
                MiddleEllipsisText(value, style: secondary),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );

    final shieldPossible = allowShield && wallet.supportsShield;
    return RoundedWhiteContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text("Pay from", style: STextStyles.smallMed12(context)),
          const SizedBox(height: 8),
          Row(
            children: [
              source("Transparent balance", false, public),
              if (shieldPossible) ...[
                const SizedBox(width: 8),
                source("Shielded balance", true, private),
              ],
            ],
          ),
          row(
            funding.fromShield ? "Notes to spend" : "Coins to spend",
            funding.coins.isEmpty
                ? "Chosen automatically"
                : "${funding.coins.length} selected · ${fmt.format(coinsTotal)}",
            [
              if (funding.coins.isNotEmpty)
                CustomTextButton(
                  text: "Reset",
                  onTap: () => onChanged((
                    fromShield: funding.fromShield,
                    coins: const {},
                    changeAddress: funding.changeAddress,
                  )),
                ),
              const SizedBox(width: 12),
              CustomTextButton(
                text: "Choose",
                onTap: () => _chooseCoins(context),
              ),
            ],
          ),
          row(
            "Change address",
            change == null
                ? funding.fromShield
                      ? "Automatic (a new private address)"
                      : "Automatic (a new change address)"
                : change,
            [
              CustomTextButton(
                text: "Choose",
                onTap: () => _chooseChange(context, coin),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One of the wallet's transparent addresses, picked from a sheet that
/// can also create a new one.
class PivxOwnAddressField extends ConsumerWidget {
  const PivxOwnAddressField({
    super.key,
    required this.walletId,
    required this.value,
    required this.onChanged,
    this.tags = const {},
  });

  final String walletId;
  final String? value;
  final ValueChanged<String> onChanged;

  /// A short note per address, e.g. "owns your delegations".
  final Map<String, String> tags;

  Future<void> _pick(BuildContext context, PivxWallet wallet) async {
    final addresses = await wallet.ownTransparentAddresses();
    if (!context.mounted) return;
    final picked = await showModalBottomSheet<String>(
      backgroundColor: Colors.transparent,
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _OwnAddressSheet(
        walletId: walletId,
        addresses: addresses,
        current: value,
        tags: tags,
        onNew: wallet.newReceivingAddress,
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = ref.watch(pWallets).getWallet(walletId) as PivxWallet;
    final address = value;
    final title = address == null ? null : pivxAddressTitle(walletId, address);
    final tag = address == null ? null : tags[address];
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _pick(context, wallet),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: address == null
                    ? Text("…", style: STextStyles.w600_14(context))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            [title, ?tag].join(" · "),
                            style: STextStyles.w600_14(context),
                          ),
                          const SizedBox(height: 2),
                          MiddleEllipsisText(
                            address,
                            style: STextStyles.w500_12(context)
                                .copyWith(color: colors.textSubtitle1),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 8),
              CustomTextButton(
                text: "Change",
                onTap: () => _pick(context, wallet),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The address label, else its kind and index.
String pivxAddressTitle(String walletId, String address) {
  final label = MainDB.instance
      .getAddressLabelSync(walletId, address)
      ?.value
      .trim();
  if (label != null && label.isNotEmpty) return label;
  final a = MainDB.instance.isar.addresses.getByValueWalletIdSync(
    address,
    walletId,
  );
  if (a == null) return "Address";
  return a.subType == AddressSubType.change
      ? "Change #${a.derivationIndex}"
      : "Receiving #${a.derivationIndex}";
}

class _OwnAddressSheet extends StatefulWidget {
  const _OwnAddressSheet({
    required this.walletId,
    required this.addresses,
    required this.current,
    required this.tags,
    required this.onNew,
  });

  final String walletId;
  final List<Address> addresses;
  final String? current;
  final Map<String, String> tags;
  final Future<String> Function() onNew;

  @override
  State<_OwnAddressSheet> createState() => _OwnAddressSheetState();
}

class _OwnAddressSheetState extends State<_OwnAddressSheet> {
  bool _creating = false;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  /// Label (or kind and index) of each address, looked up once.
  late final Map<String, String> _titles = {
    for (final a in widget.addresses)
      a.value: pivxAddressTitle(widget.walletId, a.value),
  };

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// The addresses whose value, label (or title) or tag contains the
  /// search text, ignoring case.
  List<Address> get _shown {
    final term = _search.text.trim().toLowerCase();
    if (term.isEmpty) return widget.addresses;
    return [
      for (final a in widget.addresses)
        if ([
          a.value,
          _titles[a.value]!,
          ?widget.tags[a.value],
        ].any((e) => e.toLowerCase().contains(term)))
          a,
    ];
  }

  Future<void> _new() async {
    setState(() => _creating = true);
    try {
      final address = await widget.onNew();
      if (mounted) Navigator.of(context).pop(address);
    } catch (_) {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final shown = _shown;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Container(
      // A long list keeps its height while the search narrows it.
      height: widget.addresses.length > 6
          ? (MediaQuery.sizeOf(context).height - keyboard) * 0.85
          : null,
      margin: EdgeInsets.only(bottom: keyboard),
      decoration: BoxDecoration(
        color: colors.popupBG,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text("Choose an address", style: STextStyles.pageTitleH2(context)),
            const SizedBox(height: 12),
            RoundedWhiteContainer(
              padding: EdgeInsets.zero,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _creating ? null : _new,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.add_rounded, color: colors.accentColorBlue),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Create a new address",
                          style: STextStyles.w600_14(context)
                              .copyWith(color: colors.accentColorBlue),
                        ),
                      ),
                      if (_creating)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(
                Constants.size.circularBorderRadius,
              ),
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                style: STextStyles.field(context),
                decoration:
                    standardInputDecoration(
                      "Search by address or label",
                      _searchFocus,
                      context,
                    ).copyWith(
                      prefixIcon: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 16,
                        ),
                        child: SvgPicture.asset(
                          Assets.svg.search,
                          width: 16,
                          height: 16,
                        ),
                      ),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : UnconstrainedBox(
                              child: TextFieldIconButton(
                                child: const XIcon(),
                                onTap: () => setState(_search.clear),
                              ),
                            ),
                    ),
              ),
            ),
            const SizedBox(height: 8),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  "No addresses match",
                  textAlign: TextAlign.center,
                  style: secondary,
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final a in shown)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: () => Navigator.of(context).pop(a.value),
                        child: RoundedWhiteContainer(
                          borderColor: a.value == widget.current
                              ? colors.accentColorBlue
                              : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                [
                                  _titles[a.value]!,
                                  ?widget.tags[a.value],
                                ].join(" · "),
                                style: STextStyles.w600_14(context),
                              ),
                              const SizedBox(height: 2),
                              MiddleEllipsisText(a.value, style: secondary),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
