import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../echo_context.dart';

/// Controls how [EchoPressable] exposes the semantics of its
/// [EchoPressable.child].
enum EchoPressableSemanticsMode {
  /// Exposes the pressable as one semantic node.
  ///
  /// When [EchoPressable.semanticLabel] is provided, descendant semantics are
  /// replaced by that label. This is the default for simple buttons and media
  /// rows, where announcing visible text a second time would be redundant.
  singleNode,

  /// Keeps semantic descendants as explicit nodes below the pressable.
  ///
  /// Use this for composite rows that contain independently actionable child
  /// controls. Descriptive content already covered by the parent label should
  /// be wrapped in [ExcludeSemantics] by the caller to avoid duplicate speech.
  explicitChildren,
}

/// Echo's shared interaction target.
///
/// Pointer feedback is delegated to [InkWell]. Keyboard activation is exposed
/// through Flutter's [Shortcuts] and [Actions] system, so a long-press-only
/// target still has an accessible keyboard path without changing its pointer
/// tap behavior.
///
/// 统一交互反馈：按下时子组件按 [EchoInteraction.pressedScale] 轻微缩小、
/// 松开/取消时回弹，全平台(触屏/鼠标/触控板)一律生效；鼠标右键/中键不触发。
/// 禁用时(a11y 关闭动画)自动退化为瞬时过渡，不产生缩放。
class EchoPressable extends StatefulWidget {
  const EchoPressable({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.semanticLabel,
    this.minimumSize = const Size.square(48),
    this.borderRadius,
    this.selected,
    this.toggled,
    this.semanticsMode = EchoPressableSemanticsMode.singleNode,
    this.enableHaptics = false,
    this.autofocus = false,
    this.hoverOverlayColor,
    this.pressedOverlayColor,
  }) : assert(
         semanticsMode != EchoPressableSemanticsMode.explicitChildren ||
             semanticLabel != null,
         'explicitChildren requires a semanticLabel for the parent node.',
       );

  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final String? semanticLabel;
  final Size minimumSize;
  final BorderRadius? borderRadius;
  final bool? selected;
  final bool? toggled;
  final EchoPressableSemanticsMode semanticsMode;
  final bool enableHaptics;
  final bool autofocus;

  /// 覆盖 hover 高亮色(默认取主题 accent)。供标题栏这类有特殊 hover 语义的
  /// 控件使用，例如「关闭」按钮 hover 用错误色。
  final Color? hoverOverlayColor;

  /// 覆盖按下高亮色(默认取主题 accent)。
  final Color? pressedOverlayColor;

  @override
  State<EchoPressable> createState() => _EchoPressableState();
}

class _EchoPressableState extends State<EchoPressable> {
  static const Map<ShortcutActivator, Intent> _shortcuts =
      <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      };

  /// 是否处于按压状态(驱动按压缩放动效)。
  bool _depressed = false;

  bool get _interactive =>
      widget.onPressed != null || widget.onLongPress != null;

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? context.echoRadii.control;
    final motion = context.echoMotion;
    final colors = context.echoColors;
    final interaction = context.echoInteraction;
    final hasExplicitChildren =
        widget.semanticsMode == EchoPressableSemanticsMode.explicitChildren;
    final exposesControlRole = !hasExplicitChildren || _interactive;
    final visuallyEnabled = _interactive || hasExplicitChildren;
    final hoverOverlay = widget.hoverOverlayColor ?? colors.accent;
    final pressedOverlay = widget.pressedOverlayColor ?? colors.accent;

    Widget target = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: widget.minimumSize.width.isFinite
            ? widget.minimumSize.width
            : 0,
        minHeight: widget.minimumSize.height.isFinite
            ? widget.minimumSize.height
            : 0,
      ),
      child: widget.child,
    );
    if (!widget.minimumSize.width.isFinite) {
      target = SizedBox(width: double.infinity, child: target);
    }
    if (!widget.minimumSize.height.isFinite) {
      target = SizedBox(height: double.infinity, child: target);
    }

    final Widget pressable = Semantics(
      container: true,
      explicitChildNodes: hasExplicitChildren,
      excludeSemantics:
          widget.semanticLabel != null &&
          widget.semanticsMode == EchoPressableSemanticsMode.singleNode,
      button: exposesControlRole,
      enabled: _interactive ? true : (exposesControlRole ? false : null),
      focusable: _interactive,
      selected: widget.selected,
      toggled: widget.toggled,
      label: widget.semanticLabel,
      onTap: widget.onPressed,
      onLongPress: widget.onLongPress,
      child: Shortcuts(
        shortcuts: _shortcuts,
        child: Actions(
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (intent) {
                final action = widget.onPressed ?? widget.onLongPress;
                if (action != null) _invoke(action);
                return null;
              },
            ),
          },
          child: _EchoPressableFocus(
            canRequestFocus: _interactive,
            autofocus: widget.autofocus && _interactive,
            builder: (focusContext, showFocusHighlight) {
              final focusColor = showFocusHighlight
                  ? colors.accent
                  : Colors.transparent;

              return AnimatedOpacity(
                duration: motion.resolve(context, motion.feedback),
                curve: motion.easeOut,
                opacity: visuallyEnabled ? 1 : 0.5,
                child: AnimatedContainer(
                  duration: motion.resolve(context, motion.feedback),
                  curve: motion.easeOut,
                  foregroundDecoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: focusColor,
                      width: interaction.focusRingWidth,
                    ),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: widget.onPressed == null
                          ? null
                          : () => _invoke(widget.onPressed!),
                      onLongPress: widget.onLongPress == null
                          ? null
                          : () => _invoke(widget.onLongPress!),
                      canRequestFocus: false,
                      excludeFromSemantics: true,
                      borderRadius: radius,
                      splashFactory: NoSplash.splashFactory,
                      mouseCursor: _interactive
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.basic,
                      overlayColor: WidgetStateProperty.resolveWith<Color?>(
                        (states) {
                          if (!_interactive) return Colors.transparent;
                          if (states.contains(WidgetState.pressed)) {
                            return pressedOverlay.withValues(alpha: 0.14);
                          }
                          if (states.contains(WidgetState.hovered)) {
                            return hoverOverlay.withValues(alpha: 0.08);
                          }
                          return Colors.transparent;
                        },
                      ),
                      child: target,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    // 按压缩放反馈：用 raw 指针监听(透明、不参与手势竞技场,不吞事件、不干扰
    // 滚动/拖拽)追踪按下/松开,配合 AnimatedScale 实现「按下微缩、松开回弹」。
    // 桌面端鼠标 hover 不会触发按下,只有真正按下才缩放。
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: (_) => _setDepressed(false),
      onPointerCancel: (_) => _setDepressed(false),
      behavior: HitTestBehavior.deferToChild,
      child: AnimatedScale(
        scale: _depressed && _interactive ? interaction.pressedScale : 1.0,
        duration: motion.resolve(context, motion.feedback),
        curve: motion.easeOut,
        child: pressable,
      ),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_interactive) return;
    // 排除鼠标右键/中键：仅主键(触屏或鼠标左键)触发按压反馈。
    if (event.buttons == kSecondaryButton || event.buttons == kMiddleButton) {
      return;
    }
    _setDepressed(true);
  }

  void _setDepressed(bool value) {
    if (_depressed == value) return;
    setState(() => _depressed = value);
  }

  void _invoke(VoidCallback action) {
    if (widget.enableHaptics) HapticFeedback.selectionClick();
    action();
  }
}

class _EchoPressableFocus extends StatefulWidget {
  const _EchoPressableFocus({
    required this.canRequestFocus,
    required this.autofocus,
    required this.builder,
  });

  final bool canRequestFocus;
  final bool autofocus;
  final Widget Function(BuildContext context, bool showFocusHighlight) builder;

  @override
  State<_EchoPressableFocus> createState() => _EchoPressableFocusState();
}

class _EchoPressableFocusState extends State<_EchoPressableFocus> {
  late final FocusNode _focusNode;
  late FocusHighlightMode _highlightMode;
  bool _hasPrimaryFocus = false;
  bool _listeningForHighlightMode = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'EchoPressable')
      ..addListener(_handleFocusNodeChange);
    _highlightMode = FocusManager.instance.highlightMode;
  }

  @override
  void dispose() {
    if (_listeningForHighlightMode) {
      FocusManager.instance.removeHighlightModeListener(
        _handleHighlightModeChange,
      );
    }
    _focusNode
      ..removeListener(_handleFocusNodeChange)
      ..dispose();
    super.dispose();
  }

  void _handleFocusNodeChange() {
    final hasPrimaryFocus = _focusNode.hasPrimaryFocus;
    if (_hasPrimaryFocus == hasPrimaryFocus) return;

    if (hasPrimaryFocus) {
      _highlightMode = FocusManager.instance.highlightMode;
      FocusManager.instance.addHighlightModeListener(
        _handleHighlightModeChange,
      );
      _listeningForHighlightMode = true;
    } else if (_listeningForHighlightMode) {
      FocusManager.instance.removeHighlightModeListener(
        _handleHighlightModeChange,
      );
      _listeningForHighlightMode = false;
    }

    setState(() => _hasPrimaryFocus = hasPrimaryFocus);
  }

  void _handleHighlightModeChange(FocusHighlightMode highlightMode) {
    if (_highlightMode == highlightMode) return;
    setState(() => _highlightMode = highlightMode);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      canRequestFocus: widget.canRequestFocus,
      autofocus: widget.autofocus,
      child: Builder(
        builder: (focusContext) => widget.builder(
          focusContext,
          _hasPrimaryFocus && _highlightMode == FocusHighlightMode.traditional,
        ),
      ),
    );
  }
}