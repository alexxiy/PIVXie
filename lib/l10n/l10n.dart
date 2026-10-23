import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// The app's texts in the language on screen.
///
/// A global rather than `AppLocalizations.of(context)` because many texts
/// come from code without a context: enums, exceptions, services.
/// [L10nRoot] keeps it in step with the app's locale. English until then,
/// and in tests that pump widgets without the app.
AppLocalizations get l10n => _l10n;
AppLocalizations _l10n = lookupAppLocalizations(const Locale("en"));

/// Sits under the app's Localizations and swaps [l10n] when the locale
/// changes. Widgets read [l10n] without depending on the locale, so then it
/// rebuilds all of them.
class L10nRoot extends StatefulWidget {
  const L10nRoot({super.key, required this.child});

  final Widget child;

  @override
  State<L10nRoot> createState() => _L10nRootState();
}

class _L10nRootState extends State<L10nRoot> {
  @override
  void initState() {
    super.initState();
    // Month names for DateFormat in every language (synchronous for the
    // local data, despite the Future).
    initializeDateFormatting();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = AppLocalizations.of(context);
    if (current.localeName == _l10n.localeName) return;
    _l10n = current;
    Intl.defaultLocale = current.localeName;

    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// [text] as spans, the parts between <b> and </b> in [bold]: for messages
/// that bold a few words, which can sit anywhere in a translation.
List<TextSpan> l10nSpans(
  String text, {
  required TextStyle style,
  required TextStyle bold,
}) {
  final spans = <TextSpan>[];
  final parts = text.split(RegExp(r"</?b>"));
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].isEmpty) continue;
    spans.add(TextSpan(text: parts[i], style: i.isOdd ? bold : style));
  }
  return spans;
}
