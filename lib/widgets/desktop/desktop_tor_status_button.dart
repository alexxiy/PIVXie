import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../pages_desktop_specific/desktop_menu_item.dart';
import '../../services/event_bus/events/global/tor_connection_status_changed_event.dart';
import '../../services/network_privacy.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../network_privacy.dart';

class DesktopTorStatusButton extends ConsumerStatefulWidget {
  const DesktopTorStatusButton({
    super.key,
    this.onPressed,
    required this.transitionDuration,
    this.controller,
    this.labelLength = 125,
    this.isExpandedInitially = true,
  });

  final VoidCallback? onPressed;
  final Duration transitionDuration;
  final DMIController? controller;
  final double labelLength;
  final bool isExpandedInitially;

  @override
  ConsumerState<DesktopTorStatusButton> createState() =>
      _DesktopTorStatusButtonState();
}

class _DesktopTorStatusButtonState extends ConsumerState<DesktopTorStatusButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController animationController;
  late final DMIController? controller;
  late final double labelLength;

  bool _iconOnly = false;

  void toggle() {
    setState(() {
      _iconOnly = !_iconOnly;
    });
    if (_iconOnly) {
      animationController.reverse();
    } else {
      animationController.forward();
    }
  }

  @override
  void initState() {
    labelLength = widget.labelLength;
    controller = widget.controller;

    _iconOnly = !widget.isExpandedInitially;
    controller?.toggle = toggle;
    animationController = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
      value: _iconOnly ? 0 : 1,
    );

    super.initState();
  }

  @override
  void dispose() {
    controller?.dispose();
    animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NetworkStatusBuilder(
      builder: (context, network, status) => _build(context, network, status),
    );
  }

  Widget _build(
    BuildContext context,
    PrivacyNetwork? network,
    TorConnectionStatus status,
  ) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return TextButton(
      style: Theme.of(context)
          .extension<StackColors>()!
          .getDesktopMenuButtonStyle(context),
      onPressed: widget.onPressed,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: widget.transitionDuration,
                  width: _iconOnly ? 0 : 16,
                ),
                SvgPicture.asset(
                  networkIconAsset(network),
                  color: networkStatusColor(status, colors),
                  width: 20,
                  height: 20,
                ),
                AnimatedOpacity(
                  duration: widget.transitionDuration,
                  opacity: _iconOnly ? 0 : 1.0,
                  child: SizeTransition(
                    sizeFactor: animationController,
                    axis: Axis.horizontal,
                    axisAlignment: -1,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(width: 12),
                        Text(
                          networkStatusText(network, status),
                          style: STextStyles.smallMed12(
                            context,
                          ).copyWith(color: networkStatusColor(status, colors)),
                        ),
                        const SizedBox(width: 21),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
