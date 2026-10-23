import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../themes/stack_colors.dart';
import '../utilities/constants.dart';
import '../utilities/text_styles.dart';
import '../utilities/util.dart';
import 'icon_widgets/x_icon.dart';
import 'stack_text_field.dart';
import 'textfield_icon_button.dart';

/// A Sapling memo holds 512 bytes of UTF-8: 512 Latin letters, but fewer
/// characters for accented letters (2 bytes), most other scripts (2-3) or
/// emoji (4).
const kPivxMaxMemoBytes = 512;

int utf8Length(String text) => utf8.encode(text).length;

/// [text] cut at a whole character so it takes at most [maxBytes] bytes.
String truncateUtf8(String text, int maxBytes) {
  var chars = text.characters;
  while (chars.isNotEmpty && utf8Length(chars.string) > maxBytes) {
    chars = chars.skipLast(1);
  }
  return chars.string;
}

/// Keeps the text within [maxBytes] bytes of UTF-8. Typing past the limit
/// does nothing; a paste is cut at the last whole character that fits.
class Utf8LengthLimitingFormatter extends TextInputFormatter {
  Utf8LengthLimitingFormatter(this.maxBytes);

  final int maxBytes;

  static bool _isHigh(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
  static bool _isLow(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (utf8Length(newValue.text) <= maxBytes) return newValue;

    // Shrink only what this edit inserted (between the unchanged start and
    // end), never splitting a surrogate pair.
    final before = oldValue.text;
    final text = newValue.text;
    int prefix = 0;
    while (prefix < before.length &&
        prefix < text.length &&
        before.codeUnitAt(prefix) == text.codeUnitAt(prefix)) {
      prefix++;
    }
    if (prefix > 0 && _isHigh(text.codeUnitAt(prefix - 1))) prefix--;
    int suffix = 0;
    while (suffix < before.length - prefix &&
        suffix < text.length - prefix &&
        before.codeUnitAt(before.length - 1 - suffix) ==
            text.codeUnitAt(text.length - 1 - suffix)) {
      suffix++;
    }
    if (suffix > 0 && _isLow(text.codeUnitAt(text.length - suffix))) suffix--;

    final head = text.substring(0, prefix);
    final tail = text.substring(text.length - suffix);
    final budget = maxBytes - utf8Length(head) - utf8Length(tail);
    if (budget < 0) return oldValue;
    final inserted = truncateUtf8(
      text.substring(prefix, text.length - suffix),
      budget,
    );
    return TextEditingValue(
      text: head + inserted + tail,
      selection: TextSelection.collapsed(offset: head.length + inserted.length),
    );
  }
}

/// A shielded memo input (a send to a shield address, or a payment
/// request for one), with a byte counter ("37 / 512 bytes"). [maxBytes]
/// is less where the app adds a line of its own.
class PivxMemoField extends StatelessWidget {
  const PivxMemoField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.onChanged,
    this.hint,
    this.maxBytes = kPivxMaxMemoBytes,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback? onChanged;
  final String? hint;
  final int maxBytes;

  @override
  Widget build(BuildContext context) {
    final isDesktop = Util.isDesktop;
    final colors = Theme.of(context).extension<StackColors>()!;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final bytes = utf8Length(value.text);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(
                Constants.size.circularBorderRadius,
              ),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 4,
                inputFormatters: [Utf8LengthLimitingFormatter(maxBytes)],
                style: isDesktop
                    ? STextStyles.desktopTextExtraSmall(
                        context,
                      ).copyWith(color: colors.textFieldActiveText, height: 1.8)
                    : STextStyles.field(context),
                onChanged: (_) => onChanged?.call(),
                decoration:
                    standardInputDecoration(
                      hint ?? l10n.memoHint,
                      focusNode,
                      context,
                      desktopMed: isDesktop,
                    ).copyWith(
                      contentPadding: isDesktop
                          ? const EdgeInsets.only(
                              left: 16,
                              top: 11,
                              bottom: 12,
                              right: 5,
                            )
                          : null,
                      suffixIcon: value.text.isNotEmpty
                          ? UnconstrainedBox(
                              child: TextFieldIconButton(
                                child: const XIcon(),
                                onTap: () {
                                  controller.text = "";
                                  onChanged?.call();
                                },
                              ),
                            )
                          : null,
                    ),
              ),
            ),
            if (bytes > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Text(
                  l10n.memoBytes(bytes, maxBytes),
                  textAlign: TextAlign.right,
                  style: STextStyles.label(context).copyWith(
                    color: bytes > maxBytes
                        ? colors.textError
                        : colors.textSubtitle2,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
