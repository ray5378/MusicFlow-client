import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../music_flow_context.dart';
import '../tokens/music_flow_breakpoints.dart';
import '../tokens/music_flow_spacing.dart';
import 'music_flow_anchor.dart';
import 'music_flow_icon_button.dart';
import 'music_flow_pressable.dart';
import 'music_flow_surface.dart';

Future<T?> showMusicFlowBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = false,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool desktopAnchored = false,
}) async {
  final previousFocus = FocusManager.instance.primaryFocus;
  final motion = context.musicFlowMotion;
  final duration = motion.resolve(context, motion.scene);

  final T? result;
  if (context.musicFlowWindowClass != MusicFlowWindowClass.compact) {
    if (desktopAnchored && musicFlowLastTapGlobalPosition != null) {
      // 桌面端「菜单」型弹窗:在触发点附近渲染一个小弹窗,不复用安卓式
      // 底部抽屉,也不做全屏遮盖的居中对话框(对齐 Windows 上下文菜单)。
      result = await _showAnchoredPopup<T>(
        context: context,
        useRootNavigator: useRootNavigator,
        anchor: musicFlowLastTapGlobalPosition!,
        builder: builder,
        duration: duration,
      );
    } else {
      // 桌面端(medium/expanded):不用安卓式底部抽屉,改用居中的模态弹窗,
      // 更符合 Windows「对话框」交互习惯;淡入 + 轻微缩放,共享同一动效时长。
      result = await showGeneralDialog<T>(
        context: context,
        useRootNavigator: useRootNavigator,
        barrierDismissible: isDismissible,
        barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
        barrierColor: context.musicFlowColors.scrim,
        transitionDuration: duration,
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.95, end: 1).animate(curved),
              child: child,
            ),
          );
        },
        pageBuilder: (dialogContext, animation, secondaryAnimation) => SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Material(
                type: MaterialType.transparency,
                child: FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: builder(dialogContext),
                ),
              ),
            ),
          ),
        ),
      );
    }
  } else {
    // 移动端(compact):保留安卓式底部抽屉,是手机端自然的交互。
    result = await showModalBottomSheet<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      isScrollControlled: isScrollControlled,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      useSafeArea: true,
      requestFocus: true,
      showDragHandle: false,
      elevation: 0,
      backgroundColor: Colors.transparent,
      barrierColor: context.musicFlowColors.scrim,
      clipBehavior: Clip.none,
      constraints: const BoxConstraints(maxWidth: 640),
      sheetAnimationStyle: duration == Duration.zero
          ? AnimationStyle.noAnimation
          : AnimationStyle(
              duration: duration,
              reverseDuration: motion.resolve(context, motion.state),
            ),
      builder: (sheetContext) => FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: builder(sheetContext),
      ),
    );
  }

  if (context.mounted && previousFocus?.canRequestFocus == true) {
    previousFocus!.requestFocus();
  }
  return result;
}

/// 在 [anchor]（触发点全局坐标）附近渲染一个桌面端「菜单」型小弹窗。
///
/// 不使用安卓式底部抽屉,也不做全屏遮盖(无 scrim)——外层为透明的点击拦截
/// 层,点击弹窗外区域即关闭,交互对齐 Windows 上下文菜单。弹窗自动贴边并随
/// 屏幕尺寸收缩,避免溢出。
Future<T?> _showAnchoredPopup<T>({
  required BuildContext context,
  required bool useRootNavigator,
  required Offset anchor,
  required WidgetBuilder builder,
  required Duration duration,
}) async {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  // 全局锚点 → 覆盖层本地坐标,保证在根/分支导航器里渲染时都定位正确。
  final overlayBox = navigator.overlay?.context.findRenderObject() as RenderBox?;
  final origin = overlayBox?.localToGlobal(Offset.zero) ?? Offset.zero;
  final localAnchor = anchor - origin;
  return navigator.push<T?>(
    _AnchoredPopupRoute<T>(
      anchor: localAnchor,
      builder: builder,
      duration: duration,
    ),
  );
}

class _AnchoredPopupRoute<T> extends PopupRoute<T> {
  _AnchoredPopupRoute({
    required this.anchor,
    required this.builder,
    required this.duration,
  });

  final Offset anchor;
  final WidgetBuilder builder;
  final Duration duration;

  @override
  Duration get transitionDuration => duration;

  @override
  bool get barrierDismissible => true;

  // 非全局遮盖:屏障为透明,不铺暗色遮罩,保留「在按钮旁的小弹窗」观感;
  // 同时透明屏障仍拦截点击弹窗外区域以关闭菜单(对齐 Windows 上下文菜单)。
  @override
  Color? get barrierColor => Colors.transparent;

  @override
  String? get barrierLabel => '关闭菜单';

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: _AnchoredPopupPosition(
        anchor: anchor,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: builder(context),
        ),
      ),
    );
  }
}

class _AnchoredPopupPosition extends StatelessWidget {
  const _AnchoredPopupPosition({required this.anchor, required this.child});

  static const double _margin = 8;
  static const double _gap = 6;
  static const double _preferredMaxWidth = 376;

  final Offset anchor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final panelWidth = math.min(_preferredMaxWidth, size.width - _margin * 2);

    final maxHeight = math.min(size.height * 0.7, 560.0);
    final maxBottom = size.height - _margin;

    // 默认放到触发点的右下方;空间不足时向上/向左收拢,保证不溢出屏幕。
    var top = anchor.dy + _gap;
    var left = anchor.dx + _gap;
    if (left + panelWidth > size.width - _margin) {
      left = size.width - _margin - panelWidth;
    }
    left = math.max(_margin, left);
    if (top + maxHeight > maxBottom) {
      top = math.max(_margin, maxBottom - maxHeight);
    }
    top = math.max(_margin, top);

    return SafeArea(
      child: Stack(
        children: <Widget>[
          Positioned(
            left: left,
            top: top,
            width: panelWidth,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: panelWidth,
                maxHeight: maxHeight,
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class MusicFlowBottomSheet extends StatelessWidget {
  const MusicFlowBottomSheet({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.showCloseButton = true,
    this.showDragHandle = true,
    this.sceneRadius = false,
    this.constrainToAvailableHeight = false,
    this.padding,
  });

  final String title;
  final String? subtitle;
  final bool showCloseButton;

  /// 是否显示顶部拖拽把手。桌面端锚点弹窗关闭,避免安卓式观感。
  final bool showDragHandle;

  /// 四角都使用场景圆角(桌面端弹窗),否则仅顶部圆角(底部抽屉)。
  final bool sceneRadius;
  final bool constrainToAvailableHeight;
  final EdgeInsetsGeometry? padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final sceneRadiusValue = context.musicFlowRadii.scene;
    // 桌面端居中显示时拒绝安卓式底部抽屉痕迹：隐藏 drag handle 并使用
    // 四角等圆角，呈现原生对话框观感而非手机 bottom sheet。
    final isDesktop = context.musicFlowWindowClass != MusicFlowWindowClass.compact;
    final effectiveShowDragHandle = showDragHandle && !isDesktop;
    final effectiveSceneRadius = sceneRadius || isDesktop;
    final borderRadius = effectiveSceneRadius
        ? sceneRadiusValue
        : BorderRadius.only(
            topLeft: sceneRadiusValue.topLeft,
            topRight: sceneRadiusValue.topRight,
          );

    return Semantics(
      container: true,
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: MusicFlowSurface(
        level: MusicFlowSurfaceLevel.modal,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (effectiveShowDragHandle) ...<Widget>[
                SizedBox(height: spacing.xs),
                Center(
                  child: ExcludeSemantics(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.musicFlowColors.divider,
                        borderRadius: context.musicFlowRadii.pill,
                      ),
                      child: const SizedBox(
                        key: ValueKey<String>('music_flow_bottom_sheet_drag_handle'),
                        width: 36,
                        height: 4,
                      ),
                    ),
                  ),
                ),
              ],
              Padding(
                padding: EdgeInsets.fromLTRB(
                  spacing.md,
                  spacing.sm,
                  spacing.xs,
                  subtitle == null ? spacing.sm : spacing.xxs,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: context.musicFlowTypography.headline,
                        ),
                      ),
                    ),
                    if (showCloseButton) ...<Widget>[
                      SizedBox(width: spacing.sm),
                      MusicFlowIconButton(
                        icon: AppIcons.close,
                        label: '关闭',
                        onPressed: () => Navigator.maybePop(context),
                      ),
                    ],
                  ],
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    spacing.md,
                    0,
                    spacing.md,
                    spacing.md,
                  ),
                  child: Text(
                    subtitle!,
                    style: context.musicFlowTypography.body.copyWith(
                      color: context.musicFlowColors.muted,
                    ),
                  ),
                ),
              if (constrainToAvailableHeight)
                Flexible(child: _buildBody(spacing))
              else
                _buildBody(spacing),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(MusicFlowSpacing spacing) {
    return Padding(
      padding:
          padding ??
          EdgeInsets.fromLTRB(
            spacing.md,
            subtitle == null ? spacing.xs : 0,
            spacing.md,
            spacing.md,
          ),
      child: child,
    );
  }
}

/// A domain action used inside sheets and menus. It keeps the familiar
/// icon-title-detail structure without falling back to Material [ListTile].
class MusicFlowActionRow extends StatelessWidget {
  const MusicFlowActionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onPressed,
    this.subtitle,
    this.trailing,
    this.selected = false,
    this.destructive = false,
    this.semanticLabel,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool selected;
  final bool destructive;
  final String? semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final enabled = onPressed != null;
    final accent = destructive ? colors.error : colors.accent;
    final foreground = enabled
        ? (destructive ? colors.error : colors.ink)
        : colors.onDisabled;
    final detailColor = enabled ? colors.muted : colors.onDisabled;
    final background = selected
        ? accent.withValues(alpha: 0.1)
        : enabled
        ? Colors.transparent
        : colors.raised.withValues(alpha: 0.55);
    final label =
        semanticLabel ??
        <String>[
          title,
          if (subtitle != null) subtitle!,
          if (selected) '已选择',
        ].join('，');

    return MusicFlowPressable(
      semanticLabel: label,
      selected: selected,
      onPressed: onPressed,
      minimumSize: Size(
        double.infinity,
        context.musicFlowInteraction.expandedSongRowHeight,
      ),
      borderRadius: context.musicFlowRadii.control,
      child: Ink(
        decoration: BoxDecoration(
          color: background,
          borderRadius: context.musicFlowRadii.control,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowSpacing.xs,
            vertical: context.musicFlowSpacing.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              SizedBox.square(
                dimension: context.musicFlowInteraction.minimumTouchTarget,
                child: Center(
                  child: Icon(
                    icon,
                    size: 22,
                    color: enabled ? accent : colors.onDisabled,
                  ),
                ),
              ),
              SizedBox(width: context.musicFlowSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: context.musicFlowTypography.title.copyWith(
                        color: foreground,
                      ),
                    ),
                    if (subtitle != null) ...<Widget>[
                      SizedBox(height: context.musicFlowSpacing.xxs),
                      Text(
                        subtitle!,
                        style: context.musicFlowTypography.body.copyWith(
                          color: detailColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                SizedBox(width: context.musicFlowSpacing.sm),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
