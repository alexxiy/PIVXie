import 'dart:math';

import 'package:calendar_date_picker2/calendar_date_picker2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';

import '../../l10n/l10n.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/assets.dart';
import '../../utilities/constants.dart';
import '../../utilities/format.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../adaptive_page.dart';
import '../conditional_parent.dart';
import '../desktop/primary_button.dart';
import '../desktop/secondary_button.dart';

part 'sw_date_picker.dart';

/// [value] holds selected dates. One if [range] is false. Start and end dates
/// otherwise.
Future<List<DateTime?>?> showSWDatePicker(
  BuildContext context, {
  DateTime? firstDate,
  DateTime? lastDate,
  List<DateTime?> value = const [],
  bool range = false,
}) async {
  final size = _pickerSize(context);
  final now = DateTime.now();

  final dates = await _showDatePickerDialog(
    context: context,
    value: value,
    config: CalendarDatePicker2WithActionButtonsConfig(
      firstDate: firstDate ?? DateTime(2007),
      lastDate: lastDate ?? now,
      currentDate: now,
      rangeBidirectional: range ? false : null,
      calendarType: range ? .range : null,
      buttonPadding: const EdgeInsetsDirectional.only(end: 16)
          .resolve(Directionality.of(context)),
      centerAlignModePicker: true,
      modePickerTextHandler: _monthLabelThatFits(context, size.width),
      selectedDayHighlightColor: Theme.of(context)
          .extension<StackColors>()!
          .accentColorDark,
      daySplashColor: Theme.of(context)
          .extension<StackColors>()!
          .accentColorDark
          .withOpacity(0.6),
    ),
  );

  return dates;
}

Size _pickerSize(BuildContext context) {
  if (Util.isDesktop) return const Size(450, 450);
  final room = MediaQuery.sizeOf(context);
  final padding = MediaQuery.paddingOf(context);
  // The buttons go beside the calendar: under it there's no room.
  if (ScreenFit.short(context)) {
    return Size(
      min(room.width - padding.horizontal - 32, 560),
      room.height - padding.vertical - 32,
    );
  }
  return Size(
    min(room.width - 32, 450),
    room.height >= 550 ? 450 : room.height - 32,
  );
}

/// Long month names ("November", "September") next to the year can be wider
/// than the picker header on narrow phones or with large text, and the header
/// then overflows. In that case the header shows the short name ("Nov").
/// The numbers follow the centered header of calendar_date_picker2 3.x: the
/// previous/next month arrows take 108 px, the month and year buttons are
/// 15 px apart and each has 10 px padding on both sides and a 24 px arrow.
ModePickerTextHandler _monthLabelThatFits(
  BuildContext context,
  double pickerWidth,
) {
  final locale = Localizations.localeOf(context);
  final localizations = MaterialLocalizations.of(context);
  final style = Theme.of(context).textTheme.titleSmall;
  final textDirection = Directionality.of(context);
  final textScaler = MediaQuery.textScalerOf(context);
  // The dialog stays 16 px away from the screen edges, so in a small window
  // the picker is narrower than the size it asks for.
  final screenWidth =
      MediaQuery.sizeOf(context).width -
      MediaQuery.paddingOf(context).horizontal;
  final width = min(pickerWidth, screenWidth - 32);
  final room = width - 108 - 15 - 2 * (2 * 10 + 24);

  double widthOf(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  return ({required DateTime monthDate, bool? isMonthPicker}) {
    if (isMonthPicker != true) return null;
    final full = getLocaleFullMonthFormat(locale).format(monthDate);
    final year = localizations.formatYear(monthDate);
    if (widthOf(full) + widthOf(year) <= room) return full;
    return getLocaleShortMonthFormat(locale).format(monthDate);
  };
}

Future<List<DateTime?>?> _showDatePickerDialog({
  required BuildContext context,
  required CalendarDatePicker2WithActionButtonsConfig config,
  List<DateTime?> value = const [],
  bool useRootNavigator = true,
  bool barrierDismissible = true,
  Color? barrierColor = Colors.black54,
  bool useSafeArea = true,
  RouteSettings? routeSettings,
  String? barrierLabel,
  TransitionBuilder? builder,
}) {
  // Sized on every build: the phone can rotate under an open picker.
  final dialog = Builder(
    builder: (context) {
      final size = _pickerSize(context);
      final picker = _SWDatePicker(
        value: value,
        config: config.copyWith(openedFromDialog: true),
      );
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        backgroundColor: Theme.of(context).extension<StackColors>()!.popupBG,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            Constants.size.circularBorderRadius * 2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [Flexible(child: picker)],
          ),
        ),
      );
    },
  );

  return showDialog<List<DateTime?>>(
    context: context,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    builder: (BuildContext context) {
      return builder == null ? dialog : builder(context, dialog);
    },
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
  );
}

class StackDateRangePicker extends StatelessWidget {
  const StackDateRangePicker({
    super.key,
    required this.fromDate,
    required this.toDate,
    this.firstDate,
    this.lastDate,
    required this.onChanged,
  });

  final DateTime? fromDate;
  final DateTime? toDate;
  final DateTime? firstDate, lastDate;
  final void Function(DateTime? from, DateTime? to) onChanged;

  @override
  Widget build(BuildContext context) {
    const middleSeparatorPadding = 2.0;
    const middleSeparatorWidth = 12.0;
    final isDesktop = Util.isDesktop;

    final String fromDateString = switch (fromDate) {
      null => "",
      final d => Format.formatDate(d),
    };
    final String toDateString = switch (toDate) {
      null => "",
      final d => Format.formatDate(d),
    };

    return Row(
      children: [
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const Key("transactionSearchViewFromDatePickerKey"),
              onTap: () async {
                // check and hide keyboard
                if (FocusScope.of(context).hasFocus) {
                  FocusScope.of(context).unfocus();
                  await Future<void>.delayed(const Duration(milliseconds: 125));
                }

                if (context.mounted) {
                  final date = (await showSWDatePicker(
                    context,
                    firstDate: firstDate,
                    lastDate: lastDate,
                  ))?.first;
                  if (date != null) {
                    final newFrom = date;
                    DateTime? newTo = toDate;

                    // flag to adjust date so from date is always before to date
                    if (newTo != null && !newFrom.isBefore(newTo)) {
                      newTo = DateTime.fromMillisecondsSinceEpoch(
                        newFrom.millisecondsSinceEpoch,
                      );
                    }

                    onChanged(newFrom, newTo);
                  }
                }
              },
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .extension<StackColors>()!
                      .textFieldDefaultBG,
                  borderRadius: BorderRadius.circular(
                    Constants.size.circularBorderRadius,
                  ),
                  border: Border.all(
                    color: Theme.of(context)
                        .extension<StackColors>()!
                        .textFieldDefaultBG,
                    width: 1,
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: isDesktop ? 17 : 12,
                  ),
                  child: Row(
                    children: [
                      SvgPicture.asset(
                        Assets.svg.calendar,
                        height: 20,
                        width: 20,
                        color: Theme.of(context)
                            .extension<StackColors>()!
                            .textSubtitle2,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          fromDateString.isEmpty
                              ? l10n.datePickerFrom
                              : fromDateString,
                          style: STextStyles.fieldLabel(context).copyWith(
                            color: fromDateString.isEmpty
                                ? Theme.of(context)
                                      .extension<StackColors>()!
                                      .textSubtitle2
                                : Theme.of(context)
                                      .extension<StackColors>()!
                                      .accentColorDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: middleSeparatorPadding,
          ),
          child: Container(width: middleSeparatorWidth),
        ),
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const Key("transactionSearchViewToDatePickerKey"),
              onTap: () async {
                // check and hide keyboard
                if (FocusScope.of(context).hasFocus) {
                  FocusScope.of(context).unfocus();
                  await Future<void>.delayed(const Duration(milliseconds: 125));
                }

                if (context.mounted) {
                  final date = (await showSWDatePicker(
                    context,
                    firstDate: firstDate,
                    lastDate: lastDate,
                  ))?.first;
                  if (date != null) {
                    final newTo = date;
                    DateTime? newFrom = fromDate;

                    // flag to adjust date so from date is always before to date
                    if (newFrom != null && !newTo.isAfter(newFrom)) {
                      newFrom = DateTime.fromMillisecondsSinceEpoch(
                        newTo.millisecondsSinceEpoch,
                      );
                    }

                    onChanged(newFrom, newTo);
                  }
                }
              },
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .extension<StackColors>()!
                      .textFieldDefaultBG,
                  borderRadius: BorderRadius.circular(
                    Constants.size.circularBorderRadius,
                  ),
                  border: Border.all(
                    color: Theme.of(context)
                        .extension<StackColors>()!
                        .textFieldDefaultBG,
                    width: 1,
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: isDesktop ? 17 : 12,
                  ),
                  child: Row(
                    children: [
                      SvgPicture.asset(
                        Assets.svg.calendar,
                        height: 20,
                        width: 20,
                        color: Theme.of(context)
                            .extension<StackColors>()!
                            .textSubtitle2,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          toDateString.isEmpty
                              ? l10n.datePickerTo
                              : toDateString,
                          style: STextStyles.fieldLabel(context).copyWith(
                            color: toDateString.isEmpty
                                ? Theme.of(context)
                                      .extension<StackColors>()!
                                      .textSubtitle2
                                : Theme.of(context)
                                      .extension<StackColors>()!
                                      .accentColorDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
