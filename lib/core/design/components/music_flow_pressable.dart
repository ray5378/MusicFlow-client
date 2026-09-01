import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../music_flow_context.dart';

/// Controls how [MusicFlowPressable] exposes the semantics of its
/// [MusicFlowPressable.child].
enum MusicFlowPressableSemanticsMode {
  /// Exposes the pressable as one semantic node.
  ///
  /// When [MusicFlowPressable.semanticLabel] is provided, descendant semantics are
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

/// MusicFlow's shared interaction target.
///
/// Pointer feedback is delegated to [InkWell]. Keyboard activation is exposed
/// through Flutter's [Shortcuts] and [Actions] system, so a long-press-only
/// target still has an accessible keyboard path without changing its pointer
/// tap behavior.
///
/// 统一交互反馈：按下时子组件按 [MusicFlowInteraction.pressedScale] 轻微缩小、
/// 松开/取消时回弹，全平台(触屏/鼠标/触控板)一律生效；鼠标中键不触发。
/// 鼠标右键按下时立即触发 [onLongPress]（桌面端「右键 = 长按菜单」语义，
/// InkWell 的长按只响应主按钮，故右键在此处 raw 指针层补上），且不产生
/// 按压缩放反馈；禁用时(a11y 关闭动画)自动退化为瞬时过渡，不产生缩放。
class MusicFlowPressable extends StatefulWidget {
  const MusicFlowPressable({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.semanticLabel,
    this.minimumSize = const Size.square(48),
    this.borderRadius,
    this.selected,
    this.toggled,
    this.semanticsMode = MusicFlowPressableSemanticsMode.singleNode,
    this.enableHaptics = false,
    this.autofocus = false,
    this.hoverOverlayColor,
    this.pressedOverlayColor,
  }) : assert(
         semanticsMode != MusicFlowPressableSemanticsMode.explicitChildren ||
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
  final MusicFlowPressableSemanticsMode semanticsMode;
  final bool enableHaptics;
  final bool autofocus;

  /// 覆盖 hover 高亮色(默认取主题 accent)。供标题栏这类有特殊 hover 语义的
  /// 控件使用，例如「关闭」按钮 hover 用错误色。
  final Color? hoverOverlayColor;

  /// 覆盖按下高亮色(默认取主题 accent)。
  final Color? pressedOverlayColor;

  @override
  State<MusicFlowPressable> createState() => _MusicFlowPressableState();
}

class _MusicFlowPressableState extends State<MusicFlowPressable>
    with SingleTickerProviderStateMixin {
  static const Map<ShortcutActivator, Intent> _shortcuts =
      <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      };

  /// 按压进入(按下→高亮/缩放达峰)时长。
  static const Duration _pressIn = Duration(milliseconds: 70);
  /// 按压退出(高亮渐淡消失、缩放回弹)时长。此渐变让「快速点按」也清晰可见。
  static const Duration _pressOut = Duration(milliseconds: 240);
  /// 按下高亮浓度上限,叠加在被按区域上。
  static const double _pressHighlightAlpha = 0.30;

  /// 按压动效控制器:0=静止,1=完全按下。高亮与缩放由同一控制器驱动,
  /// 松开后经 [_pressOut] 渐淡回弹——移动端与桌面端在任何点击速度下都有可见反馈。
  late final AnimationController _feedback;

  /// 是否仍处于物理按下状态(决定松开后是从峰值回弹而非停在半途)。
  bool _pressed = false;

  bool get _interactive =>
      widget.onPressed != null || widget.onLongPress != null;

  @override
  void initState() {
    super.initState();
    _feedback = AnimationController(vsync: this, duration: _pressOut);
  }

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? context.musicFlowRadii.control;
    final motion = context.musicFlowMotion;
    final colors = context.musicFlowColors;
    final interaction = context.musicFlowInteraction;
    final hasExplicitChildren =
        widget.semanticsMode == MusicFlowPressableSemanticsMode.explicitChildren;
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
          widget.semanticsMode == MusicFlowPressableSemanticsMode.singleNode,
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
                  _activatePulse();
                  final action = widget.onPressed ?? widget.onLongPress;
                  if (action != null) _invoke(action);
                  return null;
                },
            ),
          },
          child: _MusicFlowPressableFocus(
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
                          // 按下高亮由下方按压缩放反馈(Transform+前景色)统一绘制,
                          // InkWell 仅保留 hover 高亮,避免叠加浑浊。
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

    // 按压反馈：用 raw 指针监听(透明、不参与手势竞技场,不吞事件、不干扰滚动/
    // 拖拽)追踪按下/松开,由 [_feedback] 控制器统一驱动「缩放 + 高亮闪现」。
    // 点按后经 [_pressOut] 渐淡回弹,因此快速点按与桌面端鼠标左键都能看清反馈;
    // 鼠标中键与 hover 不触发；鼠标右键单独在 [_handlePointerDown] 中
    // 触发 [onLongPress]（菜单语义），同样不产生按压反馈。
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: (_) => _handlePointerRelease(),
      onPointerCancel: (_) => _handlePointerRelease(),
      behavior: HitTestBehavior.deferToChild,
      child: AnimatedBuilder(
        animation: _feedback,
        child: pressable,
        builder: (context, child) {
          final v = _feedback.value;
          return Transform.scale(
            scale: 1.0 - (1.0 - interaction.pressedScale) * v,
            child: Container(
              foregroundDecoration: BoxDecoration(
                borderRadius: radius,
                color: pressedOverlay.withValues(
                  alpha: _pressHighlightAlpha * v,
                ),
              ),
              child: child,
            ),
          );
        },
      ),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_interactive) return;
    // 鼠标右键：桌面端「右键 = 长按菜单」语义，按下立即触发 onLongPress，
    // 不参与按压反馈（InkWell 的 onLongPress 只响应主按钮长按，右键不会
    // 走那里——安卓长按正常、Windows 右键无反应的根因）。
    if (event.buttons == kSecondaryButton) {
      final longPress = widget.onLongPress;
      if (longPress != null) _invoke(longPress);
      return;
    }
    // 排除鼠标中键：仅主键(触屏或鼠标左键)触发按压反馈。
    if (event.buttons == kMiddleMouseButton) return;
    _pressed = true;
    _feedback.animateTo(1.0, duration: _pressIn);
  }

  /// 松开/取消：从峰值按 [_pressOut] 渐淡回弹,使快速点按产生可见的「闪亮→消退」。
  void _handlePointerRelease() {
    // 快速滚动/结果清空时,手指抬起可能落在已被移除的按压目标上(其组件连同
    // AnimationController 一起被 dispose),此时必须别再触碰控制器。
    if (!mounted) return;
    if (!_pressed) return;
    _pressed = false;
    _feedback.animateBack(0.0, duration: _pressOut);
  }

  /// 键盘激活(Enter/Space)时也闪现一次按压反馈,保证无障碍用户可见。
  void _activatePulse() {
    _feedback.value = 0;
    _feedback.animateTo(1.0, duration: _pressIn).whenComplete(() {
      if (mounted && !_pressed) _feedback.animateBack(0.0, duration: _pressOut);
    });
  }

  void _invoke(VoidCallback action) {
    if (widget.enableHaptics) HapticFeedback.selectionClick();
    action();
  }
}

class _MusicFlowPressableFocus extends StatefulWidget {
  const _MusicFlowPressableFocus({
    required this.canRequestFocus,
    required this.autofocus,
    required this.builder,
  });

  final bool canRequestFocus;
  final bool autofocus;
  final Widget Function(BuildContext context, bool showFocusHighlight) builder;

  @override
  State<_MusicFlowPressableFocus> createState() => _MusicFlowPressableFocusState();
}

class _MusicFlowPressableFocusState extends State<_MusicFlowPressableFocus> {
  late final FocusNode _focusNode;
  late FocusHighlightMode _highlightMode;
  bool _hasPrimaryFocus = false;
  bool _listeningForHighlightMode = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'MusicFlowPressable')
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