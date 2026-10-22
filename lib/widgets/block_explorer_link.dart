import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/providers.dart';
import '../themes/stack_colors.dart';
import '../utilities/text_styles.dart';
import '../utilities/util.dart';
import 'desktop/desktop_dialog.dart';
import 'desktop/primary_button.dart';
import 'desktop/secondary_button.dart';
import 'stack_dialog.dart';

/// Opens [uri], a block explorer page of a transaction or an address
/// ([what]), in the browser: after the privacy warning, unless the user
/// turned it off.
Future<void> openInBlockExplorer(
  BuildContext context,
  WidgetRef ref,
  Uri uri, {
  String what = "transaction",
}) async {
  if (!ref.read(prefsChangeNotifierProvider).hideBlockExplorerWarning) {
    final shouldContinue = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExplorerWarning(
        explorer: "${uri.scheme}://${uri.host}",
        what: what,
      ),
    );
    if (shouldContinue != true || !context.mounted) return;
  }

  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!opened && context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (_) => StackOkDialog(
        title: "Could not open in block explorer",
        message: "Failed to open \"$uri\"",
        maxWidth: Util.isDesktop ? 400 : null,
      ),
    );
  }
}

class _ExplorerWarning extends ConsumerWidget {
  const _ExplorerWarning({required this.explorer, required this.what});

  final String explorer;
  final String what;

  Widget _neverAgain(BuildContext context, WidgetRef ref) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Checkbox(
        value: ref.watch(
          prefsChangeNotifierProvider.select(
            (value) => value.hideBlockExplorerWarning,
          ),
        ),
        onChanged: (value) {
          if (value is bool) {
            ref.read(prefsChangeNotifierProvider).hideBlockExplorerWarning =
                value;
          }
        },
      ),
      Text("Never show again", style: STextStyles.smallMed14(context)),
    ],
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outsideTor = ref.read(prefsChangeNotifierProvider).useTor
        ? "\n\nYour browser opens it outside of Tor."
        : "";
    final message =
        "You are about to view this $what in a block explorer. The "
        "explorer may log your IP address and link it to the $what. "
        "Only proceed if you trust $explorer.$outsideTor";

    if (!Util.isDesktop) {
      final colors = Theme.of(context).extension<StackColors>()!;
      return StackDialog(
        title: "Attention",
        message: message,
        icon: _neverAgain(context, ref),
        leftButton: TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            "Cancel",
            style: STextStyles.button(
              context,
            ).copyWith(color: colors.accentColorDark),
          ),
        ),
        rightButton: TextButton(
          style: colors.getPrimaryEnabledButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text("Continue", style: STextStyles.button(context)),
        ),
      );
    }

    return DesktopDialog(
      maxWidth: 550,
      maxHeight: 300,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Attention", style: STextStyles.desktopH2(context)),
                _neverAgain(context, ref),
              ],
            ),
            const SizedBox(height: 16),
            Text(message, style: STextStyles.desktopTextSmall(context)),
            const SizedBox(height: 35),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SecondaryButton(
                  width: 200,
                  buttonHeight: ButtonHeight.l,
                  label: "Cancel",
                  onPressed: () =>
                      Navigator.of(context, rootNavigator: true).pop(false),
                ),
                const SizedBox(width: 20),
                PrimaryButton(
                  width: 200,
                  buttonHeight: ButtonHeight.l,
                  label: "Continue",
                  onPressed: () =>
                      Navigator.of(context, rootNavigator: true).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
