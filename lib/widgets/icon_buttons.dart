import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../notifications/show_flush_bar.dart';
import '../themes/stack_colors.dart';
import '../utilities/clipboard_interface.dart';
import 'icon_widgets/copy_icon.dart';
import 'icon_widgets/pencil_icon.dart';

class IconCopyButton extends StatelessWidget {
  const IconCopyButton({super.key, required this.data, this.secret = false});

  final String data;

  /// Cleared from the clipboard again after a minute (see [setSecret]).
  final bool secret;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      width: 26,
      child: RawMaterialButton(
        fillColor: Theme.of(context)
            .extension<StackColors>()!
            .buttonBackSecondary,
        elevation: 0,
        hoverElevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        onPressed: () async {
          if (secret) {
            await const ClipboardWrapper().setSecret(data);
          } else {
            await Clipboard.setData(ClipboardData(text: data));
          }
          if (context.mounted) {
            unawaited(
              showFloatingFlushBar(
                type: FlushBarType.info,
                message: l10n.commonCopiedToClipboard,
                context: context,
              ),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: CopyIcon(
            width: 16,
            height: 16,
            color: Theme.of(context).extension<StackColors>()!.textDark,
          ),
        ),
      ),
    );
  }
}

class IconPencilButton extends StatelessWidget {
  const IconPencilButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      width: 26,
      child: RawMaterialButton(
        fillColor: Theme.of(context)
            .extension<StackColors>()!
            .buttonBackSecondary,
        elevation: 0,
        hoverElevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        onPressed: () => onPressed?.call(),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: PencilIcon(
            width: 16,
            height: 16,
            color: Theme.of(context).extension<StackColors>()!.textDark,
          ),
        ),
      ),
    );
  }
}
