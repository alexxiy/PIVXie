import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/isar/main_db.dart';
import '../../l10n/l10n.dart';
import '../../models/isar/models/isar_models.dart';
import '../../providers/global/barcode_scanner_provider.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/pivx_defi/pivx_defi_api.dart';
import '../../services/pivx_defi/pivx_defi_models.dart';
import '../../services/pivx_name/pivx_name.dart';
import '../../services/pivx_name/pivx_name_resolver.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/assets.dart';
import '../../utilities/logger.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/icon_widgets/clipboard_icon.dart';
import '../../widgets/icon_widgets/qrcode_icon.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_dialog.dart';
import '../../widgets/stack_text_field.dart';
import '../send_view/sub_widgets/pivx_funding_card.dart';
import 'pivx_defi_common.dart';
import 'pivx_defi_guide.dart';
import 'pivx_defi_order_view.dart';

/// PIVXie DeFi Bridge: wrap shielded PIVX into wPIVX on BNB Smart Chain, or
/// unwrap it back. The rules are the bridge web app's (public/js/app.js):
/// the fee, the limits, the address checks and the order it creates. A
/// wrap is then paid from this wallet (or any other); an unwrap shows the
/// deposit address its wPIVX goes to.
class PivxDefiView extends ConsumerStatefulWidget {
  const PivxDefiView({super.key, required this.walletId});

  static const routeName = kPivxDefiRoute;

  final String walletId;

  @override
  ConsumerState<PivxDefiView> createState() => _PivxDefiViewState();
}

/// Where the unwrap address field stands (the web app's dest.status).
enum _Dest {
  empty,
  loading,
  ok,
  invalid,
  transparent,
  own,
  checking,
  nameOff,
  nameInvalid,
  nameNotFound,
  nameSyncing,
  nameUnreachable,
  nameRefused,
  nameNetwork,
}

/// The unwrap address field's name lookups.
const _kNameLookupDelay = Duration(milliseconds: 400);
const _kNameRetry = Duration(seconds: 15);
const _kInfoRefresh = Duration(seconds: 60);

/// The form's button: its label, and what it does when it can.
typedef _Action = ({String label, VoidCallback? run});

class _PivxDefiViewState extends ConsumerState<PivxDefiView> {
  late final PivxDefiApi _api;
  final _formKey = GlobalKey();

  final _send = TextEditingController();
  final _receive = TextEditingController();
  final _sendFocus = FocusNode();
  final _receiveFocus = FocusNode();

  /// Wrap: the BNB Smart Chain address that gets the wPIVX.
  final _evm = TextEditingController();
  final _evmFocus = FocusNode();

  /// Unwrap: the PIVX address (or PIVX name) that gets the PIVX.
  final _pivx = TextEditingController();
  final _pivxFocus = FocusNode();

  var _direction = PivxDefiDirection.wrap;

  /// The amount typed in last decides; the other follows.
  var _receiveSide = false;

  PivxDefiInfo? _info;
  Object? _infoError;
  Timer? _infoTimer;

  /// This wallet's shield address, the unwrap's default.
  String? _ownShield;

  var _dest = _Dest.empty;
  String? _destKey;
  String? _destName;
  String? _destAddress;
  var _destSeq = 0;
  Timer? _destTimer;

  var _creating = false;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  CryptoCurrency get _coin => _wallet.cryptoCurrency;

  bool get _wrap => _direction == PivxDefiDirection.wrap;

  String get _chain => _info?.chainName ?? "BNB Smart Chain";

  @override
  void initState() {
    super.initState();
    _api = PivxDefiApi.forCoin(_coin)!;
    _info = pivxDefiLastInfo;
    for (final f in [_sendFocus, _receiveFocus, _evmFocus, _pivxFocus]) {
      f.addListener(() => setState(() {}));
    }
    // The address of this wallet's last wrap.
    for (final o in _wallet.defiOrders) {
      if (o.direction == PivxDefiDirection.wrap.name && o.to != null) {
        _evm.text = o.to!;
        break;
      }
    }
    unawaited(_loadInfo());
    _infoTimer = Timer.periodic(_kInfoRefresh, (_) => _loadInfo());
    unawaited(_loadOwnShield());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(showPivxDefiGuideOnce(context, widget.walletId));
    });
  }

  @override
  void dispose() {
    _infoTimer?.cancel();
    _destTimer?.cancel();
    _destSeq++;
    for (final c in [_send, _receive, _evm, _pivx]) {
      c.dispose();
    }
    for (final f in [_sendFocus, _receiveFocus, _evmFocus, _pivxFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _loadInfo() async {
    try {
      final info = await loadPivxDefiInfo(_api);
      if (!mounted) return;
      setState(() {
        _info = info;
        _infoError = null;
        _syncAmounts();
      });
    } catch (e, s) {
      Logging.instance.w("DeFi Bridge info failed", error: e, stackTrace: s);
      if (!mounted) return;
      setState(() {
        _infoError = e;
        // A bridge that names another token isn't used at all.
        if (e is PivxDefiConfigMismatch) _info = null;
      });
    }
    // The address field waits for the settings.
    _validateAddress();
  }

  Future<void> _loadOwnShield() async {
    try {
      final address = await _wallet.getCurrentShieldAddress();
      if (!mounted || address == null) return;
      setState(() => _ownShield = address);
      if (_pivx.text.isEmpty) {
        _pivx.text = address;
        _validateAddress();
      }
    } catch (_) {}
  }

  // --- amounts ---------------------------------------------------------------

  /// Fills the amount the user isn't typing in from the one they are.
  void _syncAmounts() {
    final info = _info;
    if (info == null) return;
    if (_receiveSide) {
      final receive = parsePivxDefiAmount(_receive.text);
      final value = receive == null || receive == 0
          ? ""
          : formatPivxDefiAmount(info.sendFor(receive, _direction));
      if (_send.text != value) _send.text = value;
    } else {
      final amount = parsePivxDefiAmount(_send.text);
      final net = amount == null || amount == 0
          ? 0
          : amount - info.feeOf(amount, _direction);
      final value = net > 0 ? formatPivxDefiAmount(net) : "";
      if (_receive.text != value) _receive.text = value;
    }
  }

  void _setDirection(PivxDefiDirection d) {
    if (d == _direction) return;
    setState(() {
      _direction = d;
      _syncAmounts();
    });
  }

  // --- the unwrap address ----------------------------------------------------

  /// Checks what the unwrap address field holds. A name is looked up after
  /// a pause in typing, and only when the field or the settings changed.
  void _validateAddress() {
    final info = _info;
    final value = _pivx.text.trim();
    final key = "$value|${info?.bridgeAddresses.join(",")}|${info?.names}";
    if (key == _destKey) return;
    _destKey = key;
    final seq = ++_destSeq;
    _destTimer?.cancel();
    _destName = null;
    _destAddress = null;

    _Dest status;
    if (value.isEmpty) {
      status = _Dest.empty;
    } else if (info == null) {
      status = _Dest.loading;
    } else if (looksLikePivxName(value)) {
      final name = normalizePivxName(value);
      if (!info.names || PivxNameResolver.forCoin(_coin) == null) {
        status = _Dest.nameOff;
      } else if (name == null || !isValidPivxName(name)) {
        status = _Dest.nameInvalid;
      } else {
        _destName = name;
        status = _Dest.checking;
        _destTimer = Timer(_kNameLookupDelay, () => _checkName(seq));
      }
    } else if (_coin is Pivx && (_coin as Pivx).isShieldAddress(value)) {
      // Shielded addresses only, and never the bridge's own.
      if (info.bridgeAddresses.contains(value)) {
        status = _Dest.own;
      } else {
        status = _Dest.ok;
        _destAddress = value;
      }
    } else if (_coin is Pivx &&
        ((_coin as Pivx).isTransparentAddress(value) ||
            (_coin as Pivx).isExchangeAddress(value))) {
      status = _Dest.transparent;
    } else {
      status = _Dest.invalid;
    }
    if (mounted) setState(() => _dest = status);
  }

  /// Looks the name in the field up, and takes the address only when the
  /// chain vouches for it. A PIVX.name server catching up, or endpoints
  /// that don't answer, get another try a little later.
  Future<void> _checkName(int seq) async {
    final name = _destName;
    final resolver = PivxNameResolver.forCoin(_coin);
    if (name == null || resolver == null) return;
    final (status, address) = await _lookUp(resolver, name);
    if (seq != _destSeq || !mounted) return;
    setState(() {
      _dest = status;
      _destAddress = address;
    });
    if (status == _Dest.nameSyncing || status == _Dest.nameUnreachable) {
      _retryName(seq);
    }
  }

  Future<(_Dest, String?)> _lookUp(
    PivxNameResolver resolver,
    String name,
  ) async {
    try {
      final result = await resolver.lookup(name);
      switch (result) {
        case PivxNameVerified(:final address):
          final coin = _coin;
          if (coin is! Pivx || !coin.isShieldAddress(address)) {
            return (_Dest.nameNetwork, null);
          }
          if (_info?.bridgeAddresses.contains(address) ?? false) {
            return (_Dest.own, null);
          }
          return (_Dest.ok, address);
        case PivxNameNotRegistered():
          return (_Dest.nameNotFound, null);
        case PivxNameIndexerBehind():
          return (_Dest.nameSyncing, null);
      }
    } on PivxNameException catch (e) {
      return (e.isTransient ? _Dest.nameUnreachable : _Dest.nameRefused, null);
    } catch (e) {
      return (_Dest.nameUnreachable, null);
    }
  }

  void _retryName(int seq) {
    _destTimer = Timer(_kNameRetry, () {
      if (seq != _destSeq || !mounted) return;
      // Only while the field is in sight.
      if (_wrap) {
        _retryName(seq);
      } else {
        unawaited(_checkName(seq));
      }
    });
  }

  ({String text, Color color}) _addressHint(StackColors colors) {
    final name = _destName ?? "";
    final names = _info?.names ?? true;
    final shield = (_coin is Pivx) ? (_coin as Pivx).shieldHrp : "ps";
    final error = colors.textError;
    final subtle = colors.textSubtitle1;
    final wait = pivxDefiWarning(colors);
    return switch (_dest) {
      _Dest.empty || _Dest.loading => (
        text: names
            ? l10n.defiPivxAddressHintNames(shield)
            : l10n.defiPivxAddressHint(shield),
        color: subtle,
      ),
      _Dest.ok => (
        text: _destName != null
            ? l10n.defiNameOk(name)
            : switch (_ownTitle(_destAddress ?? "")) {
                final String title => l10n.defiPivxAddressMine(title),
                null => l10n.defiPivxAddressShield,
              },
        color: pivxDefiGreen(colors),
      ),
      _Dest.invalid => (text: l10n.defiPivxAddressInvalid, color: error),
      _Dest.transparent => (
        text: l10n.defiPivxAddressTransparent,
        color: error,
      ),
      _Dest.own => (text: l10n.defiErrorBridgeAddress, color: error),
      _Dest.checking => (text: l10n.defiNameChecking(name), color: subtle),
      _Dest.nameOff => (text: l10n.defiNameOff, color: error),
      _Dest.nameInvalid => (text: l10n.defiNameInvalid, color: error),
      _Dest.nameNotFound => (text: l10n.defiNameNotFound(name), color: error),
      _Dest.nameSyncing => (text: l10n.defiNameSyncing(name), color: wait),
      _Dest.nameUnreachable => (
        text: l10n.defiNameUnreachable(name),
        color: wait,
      ),
      _Dest.nameRefused => (text: l10n.defiNameRefused(name), color: error),
      _Dest.nameNetwork => (text: l10n.defiNameNetwork(name), color: error),
    };
  }

  // --- the wrap address ------------------------------------------------------

  /// The wrap's address as the bridge gets it (EIP-55 capitals), or null.
  String? get _evmAddress {
    final value = _evm.text.trim();
    if (!isValidEvmAddress(value)) return null;
    // The token itself never holds wPIVX for anyone.
    if (value.toLowerCase() == _api.config.token) return null;
    return evmChecksumAddress(value);
  }

  // --- fields ----------------------------------------------------------------

  Future<String?> _clipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  Future<String?> _scanned() async {
    if (FocusScope.of(context).hasFocus) {
      FocusScope.of(context).unfocus();
      await Future<void>.delayed(const Duration(milliseconds: 75));
    }
    if (!mounted) return null;
    final result = await ref.read(pBarcodeScanner).scan(context: context);
    final raw = result.rawContent?.trim();
    return raw == null || raw.isEmpty ? null : raw.split("\n").first.trim();
  }

  void _putEvm(String? text) {
    if (text == null) return;
    // A bare address, or an "ethereum:" link from a wallet's QR code.
    setState(() => _evm.text = evmAddressFromText(text) ?? text);
  }

  /// What [address] is called in this wallet (its label, else "Shield
  /// #n") when it's one of the wallet's shield addresses, else null.
  String? _ownTitle(String address) {
    if (address.isEmpty) return null;
    final row = MainDB.instance.isar.addresses.getByValueWalletIdSync(
      address,
      widget.walletId,
    );
    if (row == null || row.type != AddressType.pivxShield) return null;
    return pivxAddressTitle(widget.walletId, address);
  }

  /// One of this wallet's shield addresses, or a new one, for the payout.
  Future<void> _chooseOwn() async {
    final value = _pivx.text.trim();
    final picked = await pickPivxOwnAddress(
      context,
      wallet: _wallet,
      shield: true,
      current: _ownTitle(value) == null ? _ownShield : value,
    );
    if (!mounted || picked == null) return;
    _putPivx(picked);
  }

  void _putPivx(String? text) {
    if (text == null) return;
    // A bare address, or a "pivx:<address>?..." link.
    var value = text;
    if (value.toLowerCase().startsWith("pivx:")) value = value.substring(5);
    _pivx.text = value.split("?").first.replaceAll(RegExp(r"\s+"), "");
    _validateAddress();
  }

  // --- the action ------------------------------------------------------------

  _Action _action() {
    final info = _info;
    if (info == null) {
      return (
        label: _infoError != null ? l10n.defiUnavailable : l10n.defiLoading,
        run: null,
      );
    }
    if (!info.available) return (label: l10n.defiUnavailable, run: null);
    if (info.paused) return (label: l10n.defiPaused, run: null);

    final symbol = _wrap ? "PIVX" : "wPIVX";
    final text = _send.text.trim();
    final amount = parsePivxDefiAmount(text);
    if (text.isEmpty || amount == 0) {
      return (label: l10n.defiEnterAmount, run: null);
    }
    if (amount == null) return (label: l10n.defiInvalidAmount, run: null);
    final min = info.min(_direction);
    if (amount < min) {
      return (
        label: l10n.defiBelowMin(showPivxDefiAmount(min), symbol),
        run: null,
      );
    }
    if (_wrap && amount > info.wrapMaxSend) {
      return (
        label: l10n.defiAboveMax(showPivxDefiAmount(info.wrapMaxSend), symbol),
        run: null,
      );
    }
    if (_wrap) {
      if (_evmAddress == null) {
        return (label: l10n.defiEnterEvmAddress(_chain), run: null);
      }
    } else {
      switch (_dest) {
        case _Dest.empty:
          return (label: l10n.defiEnterAddress, run: null);
        case _Dest.checking || _Dest.nameSyncing || _Dest.nameUnreachable:
          return (label: l10n.defiNameWait, run: null);
        case _Dest.ok:
          break;
        default:
          return (
            label: _destName != null
                ? l10n.defiNameUnusable
                : l10n.defiInvalidAddress,
            run: null,
          );
      }
    }
    return (
      label: _wrap ? l10n.defiBtnWrap : l10n.defiBtnUnwrap,
      run: () => _review(info, amount),
    );
  }

  Future<void> _review(PivxDefiInfo info, int amount) async {
    FocusScope.of(context).unfocus();
    final swap = PivxDefiSwap(
      direction: _direction,
      amount: amount,
      evmAddress: _wrap ? _evmAddress : null,
      pivxAddress: _wrap ? null : _destAddress,
      pivxName: _wrap ? null : _destName,
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _ReviewDialog(info: info, swap: swap, coin: _coin),
    );
    if (ok == true && mounted) await _create(info, swap);
  }

  /// Creates the order and opens it. The order the bridge made must be the
  /// one asked for: it is paid on the bridge's word.
  Future<void> _create(PivxDefiInfo info, PivxDefiSwap swap) async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final name = swap.pivxName;
      if (name != null) {
        // The review may have stood open a while: the name must still
        // point where it showed.
        final resolver = PivxNameResolver.forCoin(_coin)!;
        final (status, address) = await _lookUp(resolver, name);
        if (!mounted) return;
        if (status != _Dest.ok || address != swap.pivxAddress) {
          _destKey = null;
          _validateAddress();
          await pivxDefiToast(
            context,
            status == _Dest.ok
                ? l10n.defiErrorNameChanged(name)
                : _addressHintFor(status, name),
            duration: const Duration(seconds: 12),
          );
          return;
        }
      }
      final order = await _api.createOrder(swap);
      if (!mounted) return;
      if (!pivxDefiOrderMatches(order, swap)) {
        await showPivxDefiMessage(
          context,
          title: l10n.commonSomethingWentWrong,
          message: l10n.defiErrorOrderMismatch,
        );
        return;
      }
      await _wallet.rememberDefiOrder(
        id: order.id,
        direction: order.direction.name,
        amount: order.amount,
        created: order.created,
        to: swap.isWrap ? swap.evmAddress : swap.pivxAddress,
        name: swap.pivxName,
      );
      pivxDefiChanged();
      if (!mounted) return;
      setState(() {
        _send.clear();
        _receive.clear();
        _receiveSide = false;
      });
      await openPivxDefiOrder(
        context,
        walletId: widget.walletId,
        id: order.id,
        order: order,
      );
    } catch (e, s) {
      Logging.instance.w("DeFi Bridge order failed", error: e, stackTrace: s);
      if (!mounted) return;
      await pivxDefiToast(context, pivxDefiErrorText(e));
      if (e is PivxDefiApiException &&
          (e.message == "The bridge is paused" ||
              e.message == "The bridge is temporarily unavailable")) {
        unawaited(_loadInfo());
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  String _addressHintFor(_Dest status, String name) => switch (status) {
    _Dest.nameNotFound => l10n.defiNameNotFound(name),
    _Dest.nameSyncing => l10n.defiNameSyncing(name),
    _Dest.nameUnreachable => l10n.defiNameUnreachable(name),
    _Dest.nameNetwork => l10n.defiNameNetwork(name),
    _Dest.own => l10n.defiErrorBridgeAddress,
    _ => l10n.defiNameRefused(name),
  };

  // --- layout ----------------------------------------------------------------

  Widget _tabs(StackColors colors) {
    Widget tab(PivxDefiDirection d, String label) {
      final active = d == _direction;
      final color = pivxDefiColor(d, colors);
      return Expanded(
        child: Material(
          color: active ? color.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _setDirection(d),
            child: Container(
              height: 40,
              alignment: Alignment.center,
              decoration: active
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                    )
                  : null,
              child: Text(
                label,
                style: STextStyles.w600_14(context)
                    .copyWith(color: active ? color : colors.textSubtitle1),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.textFieldDefaultBG,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          tab(PivxDefiDirection.wrap, l10n.defiTabWrap),
          const SizedBox(width: 4),
          tab(PivxDefiDirection.unwrap, l10n.defiTabUnwrap),
        ],
      ),
    );
  }

  Widget _tokenBox({
    required StackColors colors,
    required String label,
    required bool wrapped,
    required String network,
    required TextEditingController controller,
    required FocusNode focus,
    required bool receiveSide,
    String? note,
  }) {
    final symbol = wrapped ? "wPIVX" : "PIVX";
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: colors.textFieldDefaultBG,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: focus.hasFocus
              ? pivxDefiColor(_direction, colors).withValues(alpha: 0.6)
              : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The note goes under the label where both don't fit on one
          // line (tr in phone landscape), rather than being cut.
          Wrap(
            spacing: 6,
            children: [
              Text(
                label,
                style: STextStyles.w500_12(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
              if (note != null)
                Text(
                  note,
                  style: STextStyles.w500_12(context).copyWith(
                    color: colors.textSubtitle1.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              PivxDefiTokenIcon(coin: _coin, wrapped: wrapped, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focus,
                  textDirection: TextDirection.ltr,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  autocorrect: false,
                  enableSuggestions: false,
                  inputFormatters: [
                    TextInputFormatter.withFunction((old, value) {
                      final text = sanitizePivxDefiAmount(value.text);
                      return text == value.text
                          ? value
                          : TextEditingValue(
                              text: text,
                              selection: TextSelection.collapsed(
                                offset: text.length,
                              ),
                            );
                    }),
                  ],
                  onChanged: (_) => setState(() {
                    _receiveSide = receiveSide;
                    _syncAmounts();
                  }),
                  onSubmitted: (_) => _action().run?.call(),
                  style: STextStyles.pageTitleH1(context),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    hintText: "0.0",
                    hintStyle: STextStyles.pageTitleH1(context).copyWith(
                      color: colors.textSubtitle1.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(symbol, style: STextStyles.w600_16(context)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            network,
            style: STextStyles.w500_12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
        ],
      ),
    );
  }

  Widget _addressField({
    required StackColors colors,
    required TextEditingController controller,
    required FocusNode focus,
    required String label,
    required String hint,
    required ValueChanged<String> onChanged,
    required VoidCallback onPaste,
    required VoidCallback onScan,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: STextStyles.w600_14(context)),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: TextField(
          controller: controller,
          focusNode: focus,
          textDirection: TextDirection.ltr,
          autocorrect: false,
          enableSuggestions: false,
          maxLines: null,
          keyboardType: TextInputType.visiblePassword,
          inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r"\s"))],
          onChanged: onChanged,
          style: STextStyles.field(context),
          // The label sits above the field, so [hint] is only a placeholder.
          decoration: standardInputDecoration(null, focus, context).copyWith(
            hintText: hint,
            contentPadding: const EdgeInsetsDirectional.only(
              start: 16,
              top: 12,
              bottom: 12,
              end: 5,
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: l10n.commonPaste,
                  onPressed: onPaste,
                  icon: const ClipboardIcon(),
                ),
                IconButton(
                  tooltip: l10n.qrScanTitle,
                  onPressed: onScan,
                  icon: const QrCodeIcon(),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Widget _recipient(StackColors colors) {
    if (_wrap) {
      final value = _evm.text.trim();
      final bad = value.isNotEmpty && _evmAddress == null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _addressField(
            colors: colors,
            controller: _evm,
            focus: _evmFocus,
            label: l10n.defiEvmAddressLabel(_chain),
            hint: "0x…",
            onChanged: (_) => setState(() {}),
            onPaste: () async => _putEvm(await _clipboard()),
            onScan: () async => _putEvm(await _scanned()),
          ),
          const SizedBox(height: 6),
          Text(
            bad ? l10n.defiErrorEvmAddress : l10n.defiEvmAddressHint,
            style: STextStyles.w500_12(context)
                .copyWith(color: bad ? colors.textError : colors.textSubtitle1),
          ),
        ],
      );
    }
    final hint = _addressHint(colors);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _addressField(
          colors: colors,
          controller: _pivx,
          focus: _pivxFocus,
          label: (_info?.names ?? true)
              ? l10n.defiPivxAddressLabelNames
              : l10n.defiPivxAddressLabel,
          hint: (_coin is Pivx) ? "${(_coin as Pivx).shieldHrp}1…" : "",
          onChanged: (_) => _validateAddress(),
          onPaste: () async => _putPivx(await _clipboard()),
          onScan: () async => _putPivx(await _scanned()),
        ),
        const SizedBox(height: 6),
        Text(
          hint.text,
          style: STextStyles.w500_12(context).copyWith(color: hint.color),
        ),
        // The address a name stands for, in full: where the payout goes is
        // never out of sight.
        if (_dest == _Dest.ok && _destName != null && _destAddress != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SelectableText(
              _destAddress!,
              textDirection: TextDirection.ltr,
              style: STextStyles.w500_12(context)
                  .copyWith(color: colors.textDark),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: CustomTextButton(
              text: l10n.defiChooseMyAddress,
              onTap: _chooseOwn,
            ),
          ),
        ),
      ],
    );
  }

  Widget _details(StackColors colors, PivxDefiInfo info, int? amount) {
    final min = info.min(_direction);
    final receive = amount == null
        ? 0
        : amount - info.feeOf(amount, _direction);
    final tight =
        _wrap &&
        amount != null &&
        amount > 0 &&
        receive > info.wrapAvailable &&
        receive <= info.wrapMax;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PivxDefiRow(
          label: l10n.defiRate,
          value: _wrap ? "1 PIVX = 1 wPIVX" : "1 wPIVX = 1 PIVX",
        ),
        PivxDefiRow(
          label: l10n.defiFee,
          value: pivxDefiFeeText(info, _direction, amount),
        ),
        PivxDefiRow(
          label: l10n.defiMinimum,
          value: pivxDefiAmount(min, _wrap ? "PIVX" : "wPIVX"),
        ),
        if (_wrap)
          PivxDefiRow(
            label: l10n.defiMaximum,
            value: info.wrapMax > 0
                ? pivxDefiAmount(info.wrapMaxSend, "PIVX")
                : "-",
          ),
        PivxDefiRow(
          label: l10n.defiTime,
          value: _wrap
              ? l10n.defiTimeWrap(info.wrapMinutes.toString())
              : l10n.defiTimeUnwrap,
        ),
        if (tight) ...[
          const SizedBox(height: 8),
          PivxDefiNote(
            text: l10n.defiCapacityWarning(
              showPivxDefiAmount(info.wrapAvailable),
            ),
            color: pivxDefiWarning(colors),
            icon: Icons.schedule_rounded,
          ),
        ],
      ],
    );
  }

  Widget? _notice(StackColors colors) {
    final info = _info;
    final error = _infoError;
    if (error is PivxDefiConfigMismatch) {
      return PivxDefiNote(
        text: l10n.defiConfigMismatch,
        color: colors.textError,
        icon: Icons.block_rounded,
      );
    }
    if (error != null) {
      return PivxDefiNote(
        text: l10n.defiNoticeApiDown,
        color: colors.textError,
        icon: Icons.cloud_off_rounded,
      );
    }
    if (info == null) return null;
    if (info.paused) {
      return PivxDefiNote(
        text: l10n.defiNoticePaused,
        color: pivxDefiWarning(colors),
        icon: Icons.pause_circle_outline_rounded,
      );
    }
    if (!info.available) {
      return PivxDefiNote(
        text: l10n.defiNoticeUnavailable,
        color: pivxDefiWarning(colors),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final side = ScreenFit.sideBySide(context);
    final info = _info;
    final color = pivxDefiColor(_direction, colors);
    final amount = parsePivxDefiAmount(_send.text);
    final action = _action();
    final notice = _notice(colors);

    final intro = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Image.asset(
              _wrap ? Assets.persona.public : Assets.persona.private,
              key: ValueKey(_direction),
              height: side ? 150 : 96,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.defiHeadline,
          textAlign: TextAlign.center,
          style: STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 6),
        Text(
          _wrap
              ? "${l10n.defiSidePublic} · ${l10n.defiSidePublicSub}"
              : "${l10n.defiSidePrivate} · ${l10n.defiSidePrivateSub}",
          textAlign: TextAlign.center,
          style: STextStyles.w600_14(context).copyWith(color: color),
        ),
        const SizedBox(height: 6),
        Center(
          child: CustomTextButton(
            text: l10n.defiGuide,
            onTap: () => showPivxDefiGuide(context, widget.walletId),
          ),
        ),
        if (side) ...[
          const SizedBox(height: 16),
          Text(
            l10n.defiFootnote,
            textAlign: TextAlign.center,
            style: STextStyles.itemSubtitle(context),
          ),
        ],
      ],
    );

    final form = KeyedSubtree(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (notice != null) ...[notice, const SizedBox(height: 12)],
          RoundedWhiteContainer(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _tabs(colors),
                const SizedBox(height: 14),
                _tokenBox(
                  colors: colors,
                  label: l10n.defiYouSend,
                  wrapped: !_wrap,
                  network: _wrap ? l10n.defiNetworkPivx : _chain,
                  controller: _send,
                  focus: _sendFocus,
                  receiveSide: false,
                ),
                Center(
                  child: IconButton(
                    tooltip: l10n.defiFlip,
                    onPressed: () => _setDirection(
                      _wrap ? PivxDefiDirection.unwrap : PivxDefiDirection.wrap,
                    ),
                    icon: Icon(Icons.swap_vert_rounded, color: color),
                  ),
                ),
                _tokenBox(
                  colors: colors,
                  label: l10n.defiYouReceive,
                  note: l10n.defiAfterFee,
                  wrapped: _wrap,
                  network: _wrap ? _chain : l10n.defiNetworkPivx,
                  controller: _receive,
                  focus: _receiveFocus,
                  receiveSide: true,
                ),
                const SizedBox(height: 16),
                _recipient(colors),
                if (info != null) ...[
                  const SizedBox(height: 16),
                  _details(colors, info, amount),
                ],
                const SizedBox(height: 16),
                PrimaryButton(
                  label: _creating ? l10n.defiLoading : action.label,
                  enabled: action.run != null && !_creating,
                  buttonHeight: Util.isDesktop ? ButtonHeight.l : null,
                  onPressed: action.run,
                ),
              ],
            ),
          ),
          if (!side) ...[
            const SizedBox(height: 16),
            Text(
              l10n.defiFootnote,
              textAlign: TextAlign.center,
              style: STextStyles.w500_12(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
          ],
        ],
      ),
    );

    return Background(
      child: AppScaffold(
        maxBodyWidth: ScreenFit.panesOrColumn(context),
        backgroundColor: colors.background,
        appBar: PivxDefiAppBar(walletId: widget.walletId, config: _api.config),
        body: SafeArea(
          child: side
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: SplitPane(start: intro, end: form),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [intro, const SizedBox(height: 16), form],
                ),
        ),
      ),
    );
  }
}

/// What the order will be, before it is created.
class _ReviewDialog extends StatelessWidget {
  const _ReviewDialog({
    required this.info,
    required this.swap,
    required this.coin,
  });

  final PivxDefiInfo info;
  final PivxDefiSwap swap;
  final CryptoCurrency coin;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wrap = swap.isWrap;
    final fee = info.feeOf(swap.amount, swap.direction);
    final chain = info.chainName;
    final name = swap.pivxName;
    final notes = [
      if (wrap) ...[
        l10n.defiNoteWrapApp(showPivxDefiAmount(swap.amount)),
        l10n.defiNoteWrap2(info.wrapConfirmations.toString()),
      ] else ...[
        l10n.defiNoteUnwrap1,
        l10n.defiNoteUnwrap2,
      ],
      if (name != null) l10n.defiNoteName(name),
    ];
    Widget token(String label, int amount, bool wrapped, String network) =>
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.textFieldDefaultBG,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                label,
                style: STextStyles.w500_12(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  PivxDefiTokenIcon(coin: coin, wrapped: wrapped, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      showPivxDefiAmount(amount),
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.start,
                      style: STextStyles.pageTitleH2(context),
                    ),
                  ),
                  Text(
                    wrapped ? "wPIVX" : "PIVX",
                    style: STextStyles.w600_14(context),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                network,
                style: STextStyles.w500_12(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
            ],
          ),
        );
    return StackDialog(
      title: wrap ? l10n.defiReviewWrap : l10n.defiReviewUnwrap,
      width: Util.isDesktop ? 520 : null,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          token(
            l10n.defiYouSend,
            swap.amount,
            !wrap,
            wrap ? l10n.defiNetworkPivx : chain,
          ),
          const SizedBox(height: 8),
          token(
            l10n.defiYouReceive,
            swap.amount - fee,
            wrap,
            wrap ? chain : l10n.defiNetworkPivx,
          ),
          const SizedBox(height: 10),
          PivxDefiRow(
            label: l10n.defiFee,
            value: pivxDefiFeeText(info, swap.direction, swap.amount),
          ),
          if (name != null)
            PivxDefiRow(label: l10n.defiDetailsPivxName, value: name),
          PivxDefiRow(
            label: wrap ? l10n.defiRecipient : l10n.defiReviewPivxAddress,
            value: (wrap ? swap.evmAddress : swap.pivxAddress) ?? "",
            mono: true,
          ),
          PivxDefiRow(
            label: l10n.defiTime,
            value: wrap
                ? l10n.defiTimeWrap(info.wrapMinutes.toString())
                : l10n.defiTimeUnwrap,
          ),
          const SizedBox(height: 8),
          for (final n in notes)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "•  ",
                    style: STextStyles.w500_12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                  Expanded(
                    child: Text(
                      n,
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      leftButton: TextButton(
        style: colors.getSecondaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(
          l10n.commonCancel,
          style: STextStyles.button(context)
              .copyWith(color: colors.accentColorDark),
        ),
      ),
      rightButton: TextButton(
        style: colors.getPrimaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(l10n.defiReviewConfirm, style: STextStyles.button(context)),
      ),
    );
  }
}
