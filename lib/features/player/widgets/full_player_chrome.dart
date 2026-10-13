import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

/// 全屏播放器宽屏布局的顶部整条拖拽横幅：拖拽移动窗口、双击最大化。
///
/// 从 `full_player_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class WideDragBanner extends StatelessWidget {
  const WideDragBanner({super.key});

  Future<void> _invoke(String method) async {
    try {
      await kWindowsWindowChannel.invokeMethod<void>(method);
    } on PlatformException {
      // 窗口控制失败不影响播放。
    } on MissingPluginException {
      // 非 Windows 平台无对应原生实现。
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // [D-045] 缺陷：注释写「单击吞掉（不触发外层 onTap=_closeToMini）」，但这里用的是
      //   HitTestBehavior.translucent + SizedBox.expand（自身 hitTestSelf 为 false）⇒ 事件继续穿透到
      //   外层背景 GestureDetector ⇒ 单击 Windows 标题栏区域会关闭全屏播放器（实测点 (700,6) 复现）。
      //   建议：改 HitTestBehavior.opaque，或在外层按 Positioned 区域屏蔽。
      //   守卫用例：test/features/player/b30c_full_player_page_cov_test.dart 标题栏单击用例（钉住现状）。
      behavior: HitTestBehavior.translucent,
      // 单击吞掉(不触发外层 onTap=_closeToMini),仅拖拽/双击交给窗口。
      onTap: () {},
      onPanStart: (_) => _invoke('start_move'),
      onDoubleTap: () => _invoke('maximize_toggle'),
      child: const SizedBox.expand(),
    );
  }
}

/// 全屏播放器顶栏：左侧收起按钮 + 中部三页圆点指示器。
///
/// 从 `full_player_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class PlayerTopBar extends StatelessWidget {
  const PlayerTopBar({super.key, required this.controller, required this.onClose});

  final PageController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.musicFlowSpacing.xs),
      child: SizedBox(
        height: 56,
        child: Row(
          children: <Widget>[
            PlayerIconButton(
              icon: AppIcons.chevronDown,
              label: loc.player_collapse,
              onPressed: onClose,
            ),
            Expanded(
              child: Center(child: PageDots(controller: controller)),
            ),
            // 右侧对称占位:与左侧收起按钮等宽,保证圆点指示器水平居中。
            const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }
}

/// 三等宽圆点页签指示器：与 [PageController] 实时联动，滑动时亮度平滑插值。
/// 顺序与页面一致（左→右 = 歌词页 / 封面页 / 信息页）。
class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.controller});

  static const double _dotSize = 6;
  static const double _dotGap = 6;

  final PageController controller;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final ink = context.musicFlowColors.ink;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final page = controller.hasClients
            ? (controller.page ?? controller.initialPage.toDouble())
            : controller.initialPage.toDouble();
        final activeIndex = page.round().clamp(0, 2);
        return Semantics(
          label: loc.player_page_dots(activeIndex + 1, 3),
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (var index = 0; index < 3; index += 1) ...<Widget>[
                  if (index > 0) const SizedBox(width: _dotGap),
                  Opacity(
                    opacity:
                        0.38 +
                        0.62 * (1 - (page - index).abs()).clamp(0.0, 1.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: ink,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox.square(dimension: _dotSize),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 全屏播放器圆形图标按钮：播放控件行与工具条共用。
///
/// 从 `full_player_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class PlayerIconButton extends StatelessWidget {
  const PlayerIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.emphasized = false,
    this.dimension = 48,
    this.iconSize = 22,
    this.iconOffset = Offset.zero,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool emphasized;
  final double dimension;
  final double iconSize;
  final Offset iconOffset;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final enabled = onPressed != null;
    // 选中态用**前景色**(accent)表达，不再加一块 ink 14% 的底色：
    // 整排里只有模式 / 喜欢这类按钮会 selected，一旦它们带底色就跟旁边的
    // 上一首 / 下一首 / 播放 / 投屏（无底色纯图标）"不是一套"。
    // 与 mini 播放器同款处理（那边是 MusicFlowIconButton 的 accent 14% 底色）。
    final foreground = emphasized
        ? MusicFlowColors.readableOn(colors.ink)
        : !enabled
        ? colors.onDisabled
        : selected
        ? colors.accent
        : colors.ink;
    final background = emphasized
        ? colors.ink
        : Colors.transparent; // 永远透明：选中只靠颜色，不靠底色块

    return Tooltip(
      // 桌面端鼠标悬停显示文字注释（对齐 mini 播放器的按钮提示）；
      // 移动端长按/无障碍由 semanticLabel 承担，Tooltip 不影响触屏行为。
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: MusicFlowPressable(
        semanticLabel: label,
        selected: selected,
        onPressed: onPressed,
        enableHaptics: true,
        minimumSize: Size.square(dimension),
        borderRadius: context.musicFlowRadii.pill,
        child: SizedBox.square(
          dimension: dimension,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: context.musicFlowRadii.pill,
              // 选中**不再加边框**：整排里其余按钮都没有边框，只给个别按钮描边
              // 同样会造成"不是一套"。选中态统一只由前景色(accent)表达。
            ),
            child: Center(
              child: Transform.translate(
                key: emphasized
                    ? const ValueKey<String>(
                        'full_player_primary_transport_glyph',
                      )
                    : null,
                offset: iconOffset,
                child: Icon(icon, size: iconSize, color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
