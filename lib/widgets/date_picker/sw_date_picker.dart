part of 'date_picker.dart';

class _SWDatePicker extends StatefulWidget {
  const _SWDatePicker({required this.value, required this.config});
  final List<DateTime?> value;

  /// The calendar configurations including action buttons
  final CalendarDatePicker2WithActionButtonsConfig config;
  @override
  State<_SWDatePicker> createState() => _SWDatePickerState();
}

class _SWDatePickerState extends State<_SWDatePicker> {
  List<DateTime?> _values = [];
  List<DateTime?> _editCache = [];

  @override
  void initState() {
    _values = widget.value;
    _editCache = widget.value;
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _SWDatePicker oldWidget) {
    var isValueSame = oldWidget.value.length == widget.value.length;

    if (isValueSame) {
      for (int i = 0; i < oldWidget.value.length; i++) {
        final isSame =
            (oldWidget.value[i] == null && widget.value[i] == null) ||
                DateUtils.isSameDay(oldWidget.value[i], widget.value[i]);
        if (!isSame) {
          isValueSame = false;
          break;
        }
      }
    }

    if (!isValueSame) {
      _values = widget.value;
      _editCache = widget.value;
    }

    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        focusColor: Colors.transparent,
        colorScheme: Theme.of(context).colorScheme.copyWith(
              background: Theme.of(context).extension<StackColors>()!.popupBG,
              onBackground:
                  Theme.of(context).extension<StackColors>()!.accentColorDark,
              surface: Theme.of(context).extension<StackColors>()!.popupBG,
              surfaceVariant:
                  Theme.of(context).extension<StackColors>()!.popupBG,
              onSurface:
                  Theme.of(context).extension<StackColors>()!.accentColorDark,
              onSurfaceVariant:
                  Theme.of(context).extension<StackColors>()!.accentColorDark,
              surfaceTint: Colors.transparent,
              shadow: Colors.transparent,
            ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MediaQuery.removePadding(
            context: context,
            child: CalendarDatePicker2(
              value: [..._editCache],
              config: widget.config,
              onValueChanged: (values) => _editCache = values,
            ),
          ),
          SizedBox(height: widget.config.gapBetweenCalendarAndButtons ?? 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (!Util.isDesktop)
                SizedBox(
                  width: widget.config.buttonPadding?.right ?? 0,
                ),
              ConditionalParent(
                condition: !Util.isDesktop,
                builder: (child) => Expanded(
                  child: child,
                ),
                child: Padding(
                  padding: widget.config.buttonPadding ?? EdgeInsets.zero,
                  child: ConditionalParent(
                    condition: Util.isDesktop,
                    builder: (child) => SizedBox(
                      width: 140,
                      child: child,
                    ),
                    child: SecondaryButton(
                      label: "Cancel",
                      buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                      onPressed: () {
                        setState(
                          () {
                            _editCache = _values;
                            if ((widget.config.openedFromDialog ?? false) &&
                                (widget.config.closeDialogOnCancelTapped ??
                                    true)) {
                              Navigator.pop(context);
                            }
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
              if ((widget.config.gapBetweenCalendarAndButtons ?? 0) > 0)
                SizedBox(width: widget.config.gapBetweenCalendarAndButtons),
              ConditionalParent(
                condition: !Util.isDesktop,
                builder: (child) => Expanded(
                  child: child,
                ),
                child: Padding(
                  padding: widget.config.buttonPadding ?? EdgeInsets.zero,
                  child: ConditionalParent(
                    condition: Util.isDesktop,
                    builder: (child) => SizedBox(
                      width: 140,
                      child: child,
                    ),
                    child: PrimaryButton(
                      buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                      label: "Ok",
                      onPressed: () {
                        setState(
                          () {
                            _values = _editCache;
                            if ((widget.config.openedFromDialog ?? false) &&
                                (widget.config.closeDialogOnOkTapped ?? true)) {
                              Navigator.pop(context, _values);
                            }
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
