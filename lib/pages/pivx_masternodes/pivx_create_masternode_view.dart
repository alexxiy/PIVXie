import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';

import '../../db/isar/main_db.dart';
import '../../models/isar/models/isar_models.dart';
import '../../notifications/show_flush_bar.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_text_field.dart';
import '../send_view/confirm_transaction_view.dart';
import '../send_view/sub_widgets/building_transaction_dialog.dart';
import '../send_view/sub_widgets/pivx_funding_card.dart';
import 'pivx_masternodes_view.dart';
import '../../widgets/desktop/desktop_page_column.dart';

enum _Collateral { newAddress, ownAddress, existingOutput }

/// Create a masternode: where the collateral goes (or which output is
/// it), a label and the masternode private key.
class PivxCreateMasternodeView extends ConsumerStatefulWidget {
  const PivxCreateMasternodeView({
    super.key,
    required this.walletId,
    this.existing = false,
  });

  static const routeName = "/pivxCreateMasternode";

  final String walletId;

  /// Add a masternode that already runs (e.g. after restoring the
  /// wallet): pick its collateral output and paste its key; nothing is
  /// sent or started.
  final bool existing;

  @override
  ConsumerState<PivxCreateMasternodeView> createState() =>
      _PivxCreateMasternodeViewState();
}

class _PivxCreateMasternodeViewState
    extends ConsumerState<PivxCreateMasternodeView> {
  final _labelController = TextEditingController();
  final _labelFocus = FocusNode();
  final _addressLabelController = TextEditingController();
  final _addressLabelFocus = FocusNode();
  final _keyController = TextEditingController();
  final _keyFocus = FocusNode();
  final _serviceController = TextEditingController();
  final _serviceFocus = FocusNode();

  _Collateral _collateral = _Collateral.newAddress;
  bool _pasteKey = false;
  late String _generatedKey;

  Address? _newAddress;
  List<Address> _ownAddresses = const [];
  Address? _ownAddress;
  List<UTXO> _outputs = const [];
  UTXO? _output;

  /// Coins to pay the collateral with; empty: chosen automatically.
  /// Which balance (shield or transparent) and coins pay the collateral.
  PivxFunding _funding = kPivxAutoFunding;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  @override
  void initState() {
    _generatedKey = _wallet.generateMasternodeKey();
    _labelController.text = _wallet.nextMasternodeAlias();
    if (widget.existing) {
      _collateral = _Collateral.existingOutput;
      _pasteKey = true;
    }
    unawaited(_load());
    super.initState();
  }

  Future<void> _load() async {
    final wallet = _wallet;
    await wallet.loadMasternodeNetwork();
    var newAddress = await wallet.getCurrentReceivingAddress();
    // A collateral sent moments ago may not have moved the wallet to its
    // next address yet: never offer the same "new" address twice.
    if (newAddress != null &&
        wallet.masternodes.any((m) => m.address == newAddress!.value)) {
      await wallet.generateNewReceivingAddress();
      newAddress = await wallet.getCurrentReceivingAddress();
    }
    final own = await MainDB.instance
        .getAddresses(widget.walletId)
        .filter()
        .group(
          (q) => q
              .subTypeEqualTo(AddressSubType.receiving)
              .or()
              .subTypeEqualTo(AddressSubType.change),
        )
        .and()
        .not()
        .typeEqualTo(AddressType.pivxShield)
        .and()
        .not()
        .typeEqualTo(AddressType.nonWallet)
        .sortBySubType()
        .thenByDerivationIndex()
        .findAll();
    final outputs = await wallet.availableCollaterals();
    if (!mounted) return;
    setState(() {
      _newAddress = newAddress;
      _ownAddresses = own;
      _ownAddress = own.isEmpty ? null : own.first;
      _outputs = outputs;
      _output = outputs.isEmpty ? null : outputs.first;
    });
  }

  @override
  void dispose() {
    _labelController.dispose();
    _labelFocus.dispose();
    _addressLabelController.dispose();
    _addressLabelFocus.dispose();
    _keyController.dispose();
    _keyFocus.dispose();
    _serviceController.dispose();
    _serviceFocus.dispose();
    super.dispose();
  }

  String get _key => _pasteKey ? _keyController.text.trim() : _generatedKey;

  String? _label(String address) {
    final label = MainDB.instance
        .getAddressLabelSync(widget.walletId, address)
        ?.value
        .trim();
    return label == null || label.isEmpty ? null : label;
  }

  /// The address label, else its kind and index.
  String _addressTitle(Address a) =>
      _label(a.value) ??
      (a.subType == AddressSubType.change
          ? "Change #${a.derivationIndex}"
          : "Receiving #${a.derivationIndex}");

  Future<void> _create() async {
    final wallet = _wallet;
    if (!wallet.isValidMasternodeKey(_key)) {
      await showFloatingFlushBar(
        type: FlushBarType.warning,
        message: "Invalid masternode private key",
        context: context,
      );
      return;
    }
    final label = _labelController.text.trim();
    final aliasError = wallet.masternodeAliasError(label);
    if (aliasError != null) {
      await showFloatingFlushBar(
        type: FlushBarType.warning,
        message: aliasError,
        context: context,
      );
      return;
    }

    if (_collateral == _Collateral.existingOutput) {
      final output = _output;
      if (output == null) return;
      String? service;
      if (_serviceController.text.trim().isNotEmpty) {
        try {
          service = wallet.normalizeMasternodeService(_serviceController.text);
        } catch (e) {
          await showFloatingFlushBar(
            type: FlushBarType.warning,
            message: e is FormatException
                ? e.message
                : "Invalid server address",
            context: context,
          );
          return;
        }
      }
      await wallet.addMasternode(
        label: label,
        address: output.address ?? "",
        txid: output.txid,
        vout: output.vout,
        masternodeKey: _key,
        service: service,
      );
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final address = _collateral == _Collateral.newAddress
        ? _newAddress?.value
        : _ownAddress?.value;
    if (address == null) return;

    final prepared = await showBuildingTransaction<(TxData, int)>(
      context: context,
      coin: wallet.cryptoCurrency,
      build: () async {
        final txData = await wallet.prepareMasternodeCollateral(
          address: address,
          funding: _funding,
          note: "Create masternode $label",
        );
        return (txData, wallet.collateralVout(txData, address));
      },
    );
    if (!mounted || prepared == null) return;

    final (txData, vout) = prepared;
    final key = _key;
    final addressLabel = _collateral == _Collateral.newAddress
        ? _addressLabelController.text.trim()
        : null;
    Future<void>? saving;
    await Navigator.of(context).push(
      RouteGenerator.getRoute<void>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) => DesktopPageColumn(
          card: true,
          child: ConfirmTransactionView(
            txData: txData,
            walletId: widget.walletId,
            onSuccess: () {
              // Recorded (and its output frozen) once broadcast.
              saving = wallet.addMasternode(
                label: label,
                address: address,
                txid: txData.txid!,
                vout: vout,
                masternodeKey: key,
                addressLabel: addressLabel,
              );
            },
            onSuccessInsteadOfRouteOnSuccess: () async {
              await saving;
              if (mounted) {
                Navigator.of(
                  context,
                ).popUntil(ModalRoute.withName(PivxMasternodesView.routeName));
              }
            },
          ),
        ),
        settings: const RouteSettings(name: ConfirmTransactionView.routeName),
      ),
    );
  }

  Widget _option(_Collateral value, String title, Widget? body) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => setState(() => _collateral = value),
        child: RoundedWhiteContainer(
          borderColor: _collateral == value ? colors.accentColorBlue : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Radio<_Collateral>(
                value: value,
                groupValue: _collateral,
                activeColor: colors.radioButtonIconEnabled,
                onChanged: (v) => setState(() => _collateral = v!),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: STextStyles.titleBold12(context)),
                      if (body != null && _collateral == value) ...[
                        const SizedBox(height: 8),
                        body,
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? get _aliasError =>
      _wallet.masternodeAliasError(_labelController.text);

  String? get _keyError =>
      _pasteKey &&
          _keyController.text.trim().isNotEmpty &&
          !_wallet.isValidMasternodeKey(_keyController.text)
      ? "Not a ${_wallet.cryptoCurrency.prettyName} masternode private key"
      : null;

  String? get _serviceError => _serviceController.text.trim().isEmpty
      ? null
      : _wallet.masternodeServiceError(_serviceController.text);

  /// A text field outlined in red, with [error] under it, while its
  /// content is invalid.
  Widget _field({
    required TextEditingController controller,
    required FocusNode focus,
    required String hint,
    required String? error,
    bool plain = false,
    TextInputType? keyboardType,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final border = error == null
        ? null
        : OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: colors.textError, width: 1.5),
          );
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
            style: STextStyles.field(context),
            onChanged: (_) => setState(() {}),
            decoration: standardInputDecoration(
              hint,
              focus,
              context,
            ).copyWith(enabledBorder: border, focusedBorder: border),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Text(
              error,
              style: STextStyles.label(context)
                  .copyWith(color: colors.textError),
            ),
          ),
      ],
    );
  }

  Widget _subtitle(String text) => Text(
    text,
    style: STextStyles.w500_12(context).copyWith(
      color: Theme.of(context).extension<StackColors>()!.textSubtitle1,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final collateral =
        "${wallet.masternodeCollateral.decimal} ${wallet.cryptoCurrency.ticker}";
    final aliasError = _aliasError;
    final keyError = _keyError;
    final serviceError = widget.existing ? _serviceError : null;

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            widget.existing ? "Add existing masternode" : "Create masternode",
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.existing) ...[
                Text(
                  "For a masternode that already runs, e.g. after restoring "
                  "this wallet. Nothing is sent or started: PIVXie only "
                  "records it and freezes its collateral.",
                  style: STextStyles.itemSubtitle(context),
                ),
                const SizedBox(height: 20),
              ],
              Text("Masternode alias", style: STextStyles.smallMed12(context)),
              const SizedBox(height: 8),
              _field(
                controller: _labelController,
                focus: _labelFocus,
                hint: "e.g. MN1",
                error: aliasError,
                plain: true,
              ),
              const SizedBox(height: 20),
              Text(
                widget.existing ? "Collateral output" : "Collateral",
                style: STextStyles.smallMed12(context),
              ),
              const SizedBox(height: 8),
              if (widget.existing) ...[
                if (_outputs.isEmpty)
                  RoundedWhiteContainer(
                    child: Text(
                      "No unspent output of exactly $collateral in this "
                      "wallet. A masternode's collateral is one output of "
                      "exactly that amount.",
                      style: STextStyles.itemSubtitle(context),
                    ),
                  )
                else
                  for (final u in _outputs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: () => setState(() => _output = u),
                        child: RoundedWhiteContainer(
                          borderColor: _output == u
                              ? colors.accentColorBlue
                              : null,
                          child: Row(
                            children: [
                              Radio<UTXO>(
                                value: u,
                                groupValue: _output,
                                activeColor: colors.radioButtonIconEnabled,
                                onChanged: (v) => setState(() => _output = v),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _label(u.address ?? "") ??
                                          (u.address ?? ""),
                                      overflow: TextOverflow.ellipsis,
                                      style: STextStyles.w600_14(context),
                                    ),
                                    const SizedBox(height: 2),
                                    _subtitle(
                                      "${u.txid.substring(0, 16)}…:${u.vout}",
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                const SizedBox(height: 12),
                Text(
                  "Server IP (optional)",
                  style: STextStyles.smallMed12(context),
                ),
                const SizedBox(height: 8),
                _field(
                  controller: _serviceController,
                  focus: _serviceFocus,
                  hint:
                      "e.g. 203.0.113.5 or 203.0.113.5:${wallet.masternodePort}",
                  error: serviceError,
                  plain: true,
                  keyboardType: TextInputType.url,
                ),
              ] else ...[
                _option(
                  _Collateral.newAddress,
                  "Send $collateral to a new address",
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _subtitle(_newAddress?.value ?? "…"),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: TextField(
                          controller: _addressLabelController,
                          focusNode: _addressLabelFocus,
                          style: STextStyles.field(context),
                          decoration: standardInputDecoration(
                            "Address label (optional), e.g. "
                            "${_labelController.text.trim().isEmpty ? "MN1" : _labelController.text.trim()} "
                            "collateral",
                            _addressLabelFocus,
                            context,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_ownAddresses.isNotEmpty)
                  _option(
                    _Collateral.ownAddress,
                    "Send $collateral to one of my addresses",
                    DropdownButton<Address>(
                      isExpanded: true,
                      itemHeight: null,
                      value: _ownAddress,
                      dropdownColor: colors.popupBG,
                      items: [
                        for (final a in _ownAddresses)
                          DropdownMenuItem(
                            value: a,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _addressTitle(a),
                                    style: STextStyles.w600_14(context),
                                  ),
                                  Text(
                                    a.value,
                                    overflow: TextOverflow.ellipsis,
                                    style: STextStyles.w500_12(context)
                                        .copyWith(color: colors.textSubtitle1),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                      onChanged: (a) => setState(() => _ownAddress = a),
                    ),
                  ),
              ],
              if (_collateral != _Collateral.existingOutput) ...[
                const SizedBox(height: 4),
                PivxFundingCard(
                  walletId: widget.walletId,
                  funding: _funding,
                  amount: _wallet.masternodeCollateral,
                  onChanged: (f) => setState(() => _funding = f),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Masternode private key",
                    style: STextStyles.smallMed12(context),
                  ),
                  if (!widget.existing)
                    CustomTextButton(
                      text: _pasteKey ? "Generate one" : "I have a key",
                      onTap: () => setState(() => _pasteKey = !_pasteKey),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (_pasteKey)
                _field(
                  controller: _keyController,
                  focus: _keyFocus,
                  hint: "Paste the masternode private key",
                  error: keyError,
                  plain: true,
                )
              else
                RoundedWhiteContainer(
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          _generatedKey,
                          style: STextStyles.w500_12(context),
                        ),
                      ),
                      CustomTextButton(
                        text: "New",
                        onTap: () => setState(
                          () => _generatedKey = wallet.generateMasternodeKey(),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              _subtitle(
                "The masternode private key identifies your masternode on "
                "the network. It can't spend your coins, but keep it "
                "private. You will find it again in the masternode details.",
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                label: widget.existing ? "Add masternode" : "Send collateral",
                enabled:
                    aliasError == null &&
                    (!_pasteKey ||
                        (_keyController.text.trim().isNotEmpty &&
                            keyError == null)) &&
                    serviceError == null &&
                    (!widget.existing || _output != null),
                onPressed: _create,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
