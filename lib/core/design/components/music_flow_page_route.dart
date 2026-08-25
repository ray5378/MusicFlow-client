import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';

import '../music_flow_context.dart';

/// MusicFlow's spatial page transition for imperative navigation.
///
/// The route resolves its durations before it is pushed, so a system request
/// for reduced motion becomes an actual jump cut instead of an invisible wait.
class MusicFlowPageRoute<T> extends PageRouteBuilder<T> {
  // Explicit parameters keep the context-derived route setup in one initializer.
  // ignore: use_super_parameters
  MusicFlowPageRoute({
    required BuildContext context,
    required WidgetBuilder builder,
    RouteSettings? settings,
    bool fullscreenDialog = false,
  }) : super(
         settings: settings,
         fullscreenDialog: fullscreenDialog,
         transitionDuration: context.musicFlowMotion.resolve(
           context,
           context.musicFlowMotion.scene,
         ),
         reverseTransitionDuration: context.musicFlowMotion.resolve(
           context,
           context.musicFlowMotion.state,
         ),
         pageBuilder: (context, animation, secondaryAnimation) {
           return builder(context);
         },
         transitionsBuilder: _buildTransitions,
       );

  static Widget _buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (context.musicFlowMotion.resolve(context, context.musicFlowMotion.scene) ==
        Duration.zero) {
      return child;
    }

    final direction = Directionality.of(context) == TextDirection.ltr
        ? 1.0
        : -1.0;
    final curved = CurvedAnimation(
      parent: animation,
      curve: context.musicFlowMotion.sceneCurve,
      reverseCurve: context.musicFlowMotion.easeOut,
    );

    // Windows 走 Skia,Slide 位移叠加动画成本高:降级为 Fade-only(SEC §8.1)。
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    if (isWindows) {
      return FadeTransition(
        opacity: Tween<double>(begin: 0.86, end: 1).animate(curved),
        child: child,
      );
    }

    return FadeTransition(
      opacity: Tween<double>(begin: 0.86, end: 1).animate(curved),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0.035 * direction, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// Declarative counterpart used by GoRouter page builders.
class MusicFlowTransitionPage<T> extends Page<T> {
  const MusicFlowTransitionPage({
    required this.child,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) {
    return MusicFlowPageRoute<T>(
      context: context,
      settings: this,
      builder: (context) => child,
    );
  }
}
