import 'package:flutter/widgets.dart';

/// [child] centered in the room it's given, or scrollable when the room is
/// shorter than it: a tablet in landscape, a split screen window.
class CenterOrScroll extends StatelessWidget {
  const CenterOrScroll({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Center(child: child),
      ),
    ),
  );
}
