import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../l10n/l10n.dart';
import '../../providers/providers.dart';
import '../../services/fastest_node.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../widgets/desktop/desktop_dialog.dart';
import '../../widgets/desktop/desktop_dialog_close_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/stack_dialog.dart';

/// The node the user chose stopped answering ([NodeWatch]), waiting for the
/// unlocked wallet list ([HomeView], or DesktopHomeView) to ask them about
/// it.
final pNodeTrouble = StateProvider<NodeTrouble?>((_) => null);

/// Asks whether to switch from the node the user chose, which stopped
/// answering, to the app's bridge that answers.
Future<void> askAboutNodeTrouble(BuildContext context, WidgetRef ref) async {
  final trouble = ref.read(pNodeTrouble);
  if (trouble == null) return;
  ref.read(pNodeTrouble.notifier).state = null;
  final nodeService = ref.read(nodeServiceChangeNotifierProvider);
  // The user chose another node meanwhile.
  if (nodeService.getPrimaryNodeFor(currency: trouble.coin)?.id !=
      trouble.node.id) {
    return;
  }

  final title = l10n.nodeDownTitle(trouble.node.name);
  final text = l10n.nodeDownText(trouble.node.name, trouble.switchTo.name);
  final switchTo = await showDialog<bool>(
    context: context,
    useSafeArea: !Util.isDesktop,
    builder: (context) {
      final keep = SecondaryButton(
        buttonHeight: Util.isDesktop ? ButtonHeight.l : null,
        label: l10n.nodeDownKeep,
        onPressed: () => Navigator.of(context).pop(false),
      );
      final change = PrimaryButton(
        buttonHeight: Util.isDesktop ? ButtonHeight.l : null,
        label: l10n.nodeDownSwitch,
        onPressed: () => Navigator.of(context).pop(true),
      );
      if (!Util.isDesktop) {
        return StackDialog(
          title: title,
          message: text,
          leftButton: keep,
          rightButton: change,
        );
      }
      return DesktopDialog(
        maxHeight: double.infinity,
        maxWidth: 580,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Text(title, style: STextStyles.desktopH3(context)),
                  ),
                ),
                const DesktopDialogCloseButton(),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style: STextStyles.desktopTextSmall(context).copyWith(
                      color: Theme.of(context)
                          .extension<StackColors>()!
                          .textDark3,
                    ),
                  ),
                  const SizedBox(height: 48),
                  Row(
                    children: [
                      Expanded(child: keep),
                      const SizedBox(width: 16),
                      Expanded(child: change),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
  if (switchTo != true) return;
  // The app's bridge: the app may change it again.
  await useNode(
    trouble.coin,
    trouble.switchTo,
    nodeService,
    ref.read(prefsChangeNotifierProvider),
    () => ref.read(pWallets).wallets,
  );
}
