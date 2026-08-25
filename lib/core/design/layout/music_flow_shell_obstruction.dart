import 'package:flutter/widgets.dart';

/// Exposes the vertical space occupied by MusicFlow's bottom shell chrome.
///
/// Compact pages can use this value to keep their final interactive content
/// clear of the overlaid MiniPlayer and navigation while still painting behind
/// the transparent MiniPlayer gutter. Outside an [MusicFlowShellObstructionScope],
/// the obstruction is zero.
class MusicFlowShellObstructionScope extends InheritedWidget {
  const MusicFlowShellObstructionScope({
    super.key,
    required this.bottom,
    required super.child,
  }) : assert(bottom >= 0);

  final double bottom;

  static double of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<MusicFlowShellObstructionScope>()
            ?.bottom ??
        0;
  }

  @override
  bool updateShouldNotify(MusicFlowShellObstructionScope oldWidget) {
    return bottom != oldWidget.bottom;
  }
}

extension MusicFlowShellObstructionContext on BuildContext {
  /// Height of the bottom chrome currently covering this shell's body.
  double get musicFlowShellBottomObstruction => MusicFlowShellObstructionScope.of(this);
}
