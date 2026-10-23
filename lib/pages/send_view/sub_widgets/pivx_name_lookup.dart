import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../models/isar/models/contact_entry.dart';
import '../../../services/pivx_name/pivx_name.dart';
import '../../../services/pivx_name/pivx_name_resolver.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/logger.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../widgets/animated_widgets/rotating_arrows.dart';
import '../../../widgets/desktop/desktop_dialog.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/desktop/secondary_button.dart';
import '../../../widgets/stack_dialog.dart';

/// The PIVX.name name [input] stands for, when it is one and [coin] has
/// names (mainnet).
String? pivxNameFor(CryptoCurrency coin, String? input) =>
    PivxNameService.forCoin(coin) == null
    ? null
    : normalizePivxName(input ?? "");

/// What's wrong with a recipient that is neither an address nor a usable
/// name.
String recipientInputError(CryptoCurrency coin, String input) {
  if (!looksLikePivxName(input)) return l10n.sendInvalidAddress;
  return PivxNameService.forCoin(coin) == null
      ? l10n.sendNamesMainnetOnly
      : l10n.sendNameInvalid;
}

/// Placeholder of the recipient field.
String recipientHint(CryptoCurrency coin) =>
    PivxNameService.forCoin(coin) == null
    ? l10n.sendEnterAddress(coin.ticker)
    : l10n.sendEnterAddressOrName(coin.ticker);

/// [e]'s message in the language on screen. The resolver writes English,
/// with what it knows of the case; other languages get the gist of each kind.
String pivxNameErrorText(PivxNameException e, {bool detail = false}) {
  if (l10n.localeName == "en") return detail ? e.toString() : e.message;
  return switch (e.kind) {
    PivxNameError.indexerUnreachable => l10n.pivxNameErrorUnreachable,
    PivxNameError.indexerError => l10n.pivxNameErrorIndexer,
    PivxNameError.chainUnavailable => l10n.pivxNameErrorChainUnavailable,
    PivxNameError.chainDisagreement => l10n.pivxNameErrorChainDisagreement,
    PivxNameError.unreviewedEpoch => l10n.pivxNameErrorEpoch,
    PivxNameError.unanchoredRoot => l10n.pivxNameErrorUnanchored,
    PivxNameError.badRecord => l10n.pivxNameErrorBadRecord,
    PivxNameError.unavailable => l10n.pivxNameErrorUnavailable,
  };
}

/// Looks [name] up for a payment, behind a dialog, and returns the verified
/// result; null when the user cancels or it can't be verified (the dialog
/// has said why). Nothing is sent from here: the confirm screen does that,
/// after checking the name again.
Future<PivxNameVerified?> lookUpPivxNameForSend({
  required BuildContext context,
  required CryptoCurrency coin,
  required String name,
  required List<ContactEntry> contacts,
  PivxNameResolver? resolver,
}) async {
  final lookups = resolver ?? PivxNameResolver.forCoin(coin);
  if (lookups == null) return null;

  // A typed name that is also a contact's name: the user may mean either,
  // and they can be different people (a nickname someone else has since
  // registered, or a contact added from a link to shadow a real name).
  // Neither reading is safe to pick. A contact chosen from the address book
  // never gets here: the form then holds the contact's saved address.
  if (contacts.any((c) => c.name.trim().toLowerCase() == name)) {
    await _showMessage(
      context,
      title: l10n.sendNameIsContact(name),
      message: l10n.sendNameIsContactText,
    );
    return null;
  }

  return showDialog<PivxNameVerified>(
    context: context,
    useSafeArea: false,
    barrierDismissible: false,
    builder: (_) => PivxNameLookupDialog(resolver: lookups, name: name),
  );
}

Future<void> _showMessage(
  BuildContext context, {
  required String title,
  required String message,
}) => showDialog<void>(
  context: context,
  useSafeArea: false,
  builder: (context) => Util.isDesktop
      ? _DesktopBody(
          title: title,
          message: message,
          buttons: [
            PrimaryButton(
              buttonHeight: ButtonHeight.l,
              label: l10n.commonOk,
              onPressed: Navigator.of(context).pop,
            ),
          ],
        )
      : StackDialog(
          title: title,
          message: message,
          rightButton: _mobileButton(
            context,
            l10n.commonOk,
            Navigator.of(context).pop,
            primary: true,
          ),
        ),
);

enum _Stage { checking, waiting, notRegistered, failed }

/// Runs one lookup and, while the PIVX.name server is behind, checks every
/// 15 seconds whether it has caught up. Pops with the verified result.
class PivxNameLookupDialog extends StatefulWidget {
  const PivxNameLookupDialog({
    super.key,
    required this.resolver,
    required this.name,
    this.pollEvery = const Duration(seconds: 15),
    this.giveUpAfter = const Duration(minutes: 20),
  });

  final PivxNameResolver resolver;
  final String name;
  final Duration pollEvery;
  final Duration giveUpAfter;

  @override
  State<PivxNameLookupDialog> createState() => _PivxNameLookupDialogState();
}

class _PivxNameLookupDialogState extends State<PivxNameLookupDialog> {
  var _stage = _Stage.checking;
  var _nameMissing = false;
  String? _failure;
  String? _failureDetail;
  var _canRetry = false;

  Timer? _poll;
  DateTime? _waitingSince;
  var _polling = false;

  /// Bumped by every new run and by closing; a result from an older run is
  /// dropped.
  var _run = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_lookup());
  }

  @override
  void dispose() {
    _run++;
    _stopPolling();
    super.dispose();
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _lookup() async {
    final run = ++_run;
    _stopPolling();
    if (_stage != _Stage.checking) {
      setState(() => _stage = _Stage.checking);
    }
    try {
      _apply(await widget.resolver.lookup(widget.name), run);
    } catch (e, s) {
      if (run != _run || !mounted) return;
      Logging.instance.w("PIVX.name lookup failed", error: e, stackTrace: s);
      _fail(e);
    }
  }

  void _apply(PivxNameLookup result, int run) {
    if (run != _run || !mounted) return;
    switch (result) {
      case PivxNameVerified():
        Navigator.of(context).pop(result);
      case PivxNameNotRegistered():
        _stopPolling();
        setState(() => _stage = _Stage.notRegistered);
      case PivxNameIndexerBehind(:final nameMissing):
        _waitingSince ??= DateTime.now();
        setState(() {
          _stage = _Stage.waiting;
          _nameMissing = nameMissing;
        });
        _poll ??= Timer.periodic(widget.pollEvery, (_) => _tick(run));
    }
  }

  /// Only asks whether the server has caught up; the full lookup runs again
  /// once it has.
  Future<void> _tick(int run) async {
    if (_polling || run != _run) return;
    if (DateTime.now().difference(_waitingSince!) > widget.giveUpAfter) {
      _stopPolling();
      setState(() {
        _stage = _Stage.failed;
        _failure = l10n.sendNameNotCaughtUp;
        _failureDetail = null;
        _canRetry = true;
      });
      return;
    }
    _polling = true;
    try {
      if (!await widget.resolver.caughtUp()) return;
      if (run != _run || !mounted) return;
      _stopPolling();
      _apply(await widget.resolver.lookup(widget.name), run);
    } on PivxNameException catch (e) {
      // A server that is briefly out of reach changes nothing; keep waiting.
      if (!e.isTransient && run == _run && mounted) _fail(e);
    } catch (e) {
      if (run == _run && mounted) _fail(e);
    } finally {
      _polling = false;
    }
  }

  void _fail(Object e) {
    _stopPolling();
    setState(() {
      _stage = _Stage.failed;
      if (e is PivxNameException) {
        _failure = pivxNameErrorText(e);
        _failureDetail = l10n.localeName == "en" ? e.detail : null;
        _canRetry = e.isTransient;
      } else {
        _failure = l10n.sendNameCheckFailed(widget.name);
        _failureDetail = null;
        _canRetry = true;
      }
    });
  }

  void _close() {
    _run++;
    _stopPolling();
    Navigator.of(context).pop();
  }

  void _retry() {
    _waitingSince = null;
    unawaited(_lookup());
  }

  String get _title => switch (_stage) {
    _Stage.checking => l10n.sendNameChecking(widget.name),
    _Stage.waiting => l10n.sendNameWaiting,
    _Stage.notRegistered => l10n.sendNameNotFound,
    _Stage.failed => l10n.sendNameCantSend(widget.name),
  };

  String get _message => switch (_stage) {
    _Stage.checking => l10n.sendNameCheckingText,
    _Stage.waiting when _nameMissing => l10n.sendNameWaitingMissing(
      widget.name,
    ),
    _Stage.waiting => l10n.sendNameWaitingText(widget.name),
    _Stage.notRegistered => l10n.sendNameNotRegistered(widget.name),
    _Stage.failed =>
      _failureDetail == null ? _failure! : "$_failure\n\n$_failureDetail",
  };

  bool get _busy => _stage == _Stage.checking || _stage == _Stage.waiting;

  @override
  Widget build(BuildContext context) {
    final retry = _stage == _Stage.failed && _canRetry;
    final closeLabel = _busy ? l10n.commonCancel : l10n.commonClose;

    final Widget dialog;
    if (Util.isDesktop) {
      dialog = _DesktopBody(
        title: _title,
        message: _message,
        busy: _busy,
        buttons: [
          SecondaryButton(
            buttonHeight: ButtonHeight.l,
            label: closeLabel,
            onPressed: _close,
          ),
          if (retry)
            PrimaryButton(
              buttonHeight: ButtonHeight.l,
              label: l10n.commonTryAgain,
              onPressed: _retry,
            ),
        ],
      );
    } else {
      dialog = StackDialog(
        title: _title,
        message: _message,
        icon: _busy ? const RotatingArrows(width: 24, height: 24) : null,
        leftButton: retry ? _mobileButton(context, closeLabel, _close) : null,
        rightButton: retry
            ? _mobileButton(context, l10n.commonTryAgain, _retry, primary: true)
            : _mobileButton(context, closeLabel, _close),
      );
    }
    // Back is the same as Cancel.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: dialog,
    );
  }
}

Widget _mobileButton(
  BuildContext context,
  String label,
  VoidCallback onPressed, {
  bool primary = false,
}) {
  final colors = Theme.of(context).extension<StackColors>()!;
  return TextButton(
    style: primary
        ? colors.getPrimaryEnabledButtonStyle(context)
        : colors.getSecondaryEnabledButtonStyle(context),
    onPressed: onPressed,
    child: Text(
      label,
      style: primary
          ? STextStyles.button(context)
          : STextStyles.button(context).copyWith(color: colors.accentColorDark),
    ),
  );
}

class _DesktopBody extends StatelessWidget {
  const _DesktopBody({
    required this.title,
    required this.message,
    required this.buttons,
    this.busy = false,
  });

  final String title;
  final String message;
  final List<Widget> buttons;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return DesktopDialog(
      maxWidth: 500,
      maxHeight: double.infinity,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: STextStyles.desktopH3(context)),
                ),
                if (busy) const RotatingArrows(width: 32, height: 32),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: STextStyles.desktopTextExtraExtraSmall(context)
                  .copyWith(fontSize: 18),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i > 0) const SizedBox(width: 16),
                  Expanded(child: buttons[i]),
                ],
                if (buttons.length == 1) ...[
                  const SizedBox(width: 16),
                  const Spacer(),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
