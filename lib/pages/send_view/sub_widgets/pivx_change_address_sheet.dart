import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';

import '../../../db/isar/main_db.dart';
import '../../../models/isar/models/isar_models.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/stack_text_field.dart';

/// Picks where the change of a PIVX send goes: automatic (a new change
/// address of the wallet), one of the wallet's addresses, or any other
/// address. Transparent addresses for sends from the public balance,
/// shield addresses ([shield]) for sends from the shield balance.
///
/// Pops "" for automatic, an address, or null when dismissed.
class PivxChangeAddressSheet extends ConsumerStatefulWidget {
  const PivxChangeAddressSheet({
    super.key,
    required this.walletId,
    required this.coin,
    this.current,
    this.shield = false,
  });

  /// Shield change (send from the shield balance).
  final bool shield;

  final String walletId;
  final Pivx coin;

  /// Currently chosen address (null = automatic).
  final String? current;

  @override
  ConsumerState<PivxChangeAddressSheet> createState() =>
      _PivxChangeAddressSheetState();
}

class _PivxChangeAddressSheetState
    extends ConsumerState<PivxChangeAddressSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  late final List<Address> _addresses;

  @override
  void initState() {
    final query = MainDB.instance.getAddresses(widget.walletId).filter();
    _addresses =
        (widget.shield
                ? query.typeEqualTo(AddressType.pivxShield)
                : query.not().typeEqualTo(AddressType.pivxShield))
            .sortBySubType()
            .thenByDerivationIndex()
            .findAllSync();
    final current = widget.current;
    if (current != null && !_addresses.any((a) => a.value == current)) {
      _controller.text = current;
    }
    super.initState();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The address label, else its kind and index.
  String _title(Address a) {
    final label = MainDB.instance
        .getAddressLabelSync(widget.walletId, a.value)
        ?.value
        .trim();
    if (label != null && label.isNotEmpty) return label;
    if (a.type == AddressType.pivxShield) return "Shield #${a.derivationIndex}";
    return a.subType == AddressSubType.change
        ? "Change #${a.derivationIndex}"
        : "Receiving #${a.derivationIndex}";
  }

  void _useCustom() {
    final address = _controller.text.trim();
    if (widget.shield
        ? !widget.coin.isShieldAddress(address)
        : !widget.coin.isTransparentAddress(address)) {
      setState(
        () => _error = widget.shield
            ? "Not a shield PIVX address"
            : "Not a transparent PIVX address",
      );
      return;
    }
    Navigator.of(context).pop(address);
  }

  Widget _option({
    required String title,
    String? subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        child: RoundedWhiteContainer(
          borderColor: selected ? colors.accentColorBlue : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: STextStyles.w600_14(context)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: STextStyles.w500_12(
                    context,
                  ).copyWith(color: colors.textSubtitle1),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: BoxDecoration(
          color: colors.popupBG,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                decoration: BoxDecoration(
                  color: colors.textFieldDefaultBG,
                  borderRadius: BorderRadius.circular(
                    Constants.size.circularBorderRadius,
                  ),
                ),
                width: 60,
                height: 4,
              ),
            ),
            const SizedBox(height: 24),
            Text("Change address", style: STextStyles.pageTitleH2(context)),
            const SizedBox(height: 16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  _option(
                    title: "Automatic",
                    subtitle: widget.shield
                        ? "A new shield address of this wallet"
                        : "A new change address of this wallet",
                    selected: widget.current == null,
                    onTap: () => Navigator.of(context).pop(""),
                  ),
                  for (final a in _addresses)
                    _option(
                      title: _title(a),
                      subtitle: a.value,
                      selected: widget.current == a.value,
                      onTap: () => Navigator.of(context).pop(a.value),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(
                Constants.size.circularBorderRadius,
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                autocorrect: false,
                enableSuggestions: false,
                style: STextStyles.field(context),
                onChanged: (_) => setState(() => _error = null),
                decoration: standardInputDecoration(
                  widget.shield
                      ? "Other shield address"
                      : "Other transparent address",
                  _focus,
                  context,
                ).copyWith(errorText: _error),
              ),
            ),
            const SizedBox(height: 12),
            PrimaryButton(label: "Use this address", onPressed: _useCustom),
          ],
        ),
      ),
    );
  }
}
