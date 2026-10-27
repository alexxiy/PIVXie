import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';

import '../themes/stack_colors.dart';
import '../utilities/assets.dart';
import '../utilities/test_node_connection.dart';

/// A node's network icon: green when it's the one in use, and once the node
/// was tested, how good the connection was, [NodeTestResult.level] of its
/// four bars green and the rest grey.
class NodeSignalIcon extends ConsumerWidget {
  const NodeSignalIcon({
    super.key,
    required this.nodeId,
    required this.connected,
    this.size = 20,
  });

  final String nodeId;
  final bool connected;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final result = ref.watch(
      pNodeTests.select((value) => value.resultFor(nodeId)),
    );
    if (result == null) {
      return SvgPicture.asset(
        Assets.svg.network,
        color: connected ? colors.accentColorGreen : colors.buttonBackSecondary,
        width: size,
        height: size,
      );
    }

    // The icon's bars, drawn on its 16-unit grid.
    final unit = size / 16;
    return SizedBox(
      width: size,
      height: size,
      child: Padding(
        padding: EdgeInsets.fromLTRB(0.67 * unit, 0, 0.67 * unit, 2 * unit),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 1; i <= NodeTestResult.maxLevel; i++)
              Container(
                width: 2.44 * unit,
                height: 3.17 * unit * i,
                decoration: BoxDecoration(
                  color: i <= result.level
                      ? colors.accentColorGreen
                      : colors.buttonBackSecondary,
                  borderRadius: BorderRadius.circular(1.22 * unit),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
