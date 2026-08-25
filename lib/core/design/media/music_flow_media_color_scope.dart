import 'package:flutter/material.dart';

import '../tokens/music_flow_colors.dart';
import '../tokens/music_flow_typography.dart';
import 'music_flow_media_visuals.dart';

enum MusicFlowMediaSurfaceRole { stage, mini, panel }

/// Installs artwork-derived Echo tokens for one media-led subtree.
///
/// Spacing, radii, motion, breakpoints, and interaction extensions are kept
/// from the parent theme. Only colour and typography semantics are replaced.
class MusicFlowMediaColorScope extends StatelessWidget {
  const MusicFlowMediaColorScope({
    super.key,
    required this.visuals,
    required this.role,
    required this.child,
  });

  final MusicFlowMediaVisuals visuals;
  final MusicFlowMediaSurfaceRole role;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final parentTheme = Theme.of(context);
    final parentColors =
        parentTheme.extension<MusicFlowColors>() ??
        (parentTheme.brightness == Brightness.dark
            ? MusicFlowColors.dark()
            : MusicFlowColors.light());
    final parentTypography =
        parentTheme.extension<MusicFlowTypography>() ??
        MusicFlowTypography.standard(parentColors);
    final colors = _mediaColors(parentColors, visuals, role);
    final typography = _mediaTypography(parentTypography, colors);
    final extensions =
        List<ThemeExtension<dynamic>>.of(parentTheme.extensions.values)
          ..removeWhere(
            (extension) =>
                extension is MusicFlowColors || extension is MusicFlowTypography,
          );
    extensions.addAll(<ThemeExtension<dynamic>>[colors, typography]);

    // 媒体面板表面取自专辑调色板,可能与全局主题的明暗不一致(例如深色主题 +
    // 浅色封面会把 panel 表面拉近白)。此时若任何控件退回 Material 默认前景
    // (暗色主题下 colorScheme.onSurface = 白),就会在白底上渲染出白字。这里把
    // 基础 Material 角色的前景一并重映射到已保证对比的 ink/muted,使「白底白字」
    // 在地域内被彻底封死,而不仅仅是 musicFlow 语义色。
    final bool mediaIsDark = colors.ink.computeLuminance() > 0.45;
    final ColorScheme scheme = parentTheme.colorScheme.copyWith(
      brightness: mediaIsDark ? Brightness.dark : Brightness.light,
      surface: colors.surface,
      surfaceContainerLowest: colors.canvas,
      surfaceContainerLow: colors.raised,
      surfaceContainer: colors.raised,
      surfaceContainerHigh: colors.surface,
      surfaceContainerHighest: colors.raised,
      onSurface: colors.ink,
      onSurfaceVariant: colors.muted,
      primary: colors.accent,
      onPrimary: colors.onAccent,
      secondary: colors.accent,
      onSecondary: colors.onAccent,
      error: colors.error,
      onError: colors.onError,
      outline: colors.controlBoundary,
      outlineVariant: colors.divider,
    );

    // 把 Material 默认文字前景统一压到已保证对比的 ink(对浅色面板即黑色):
    // 直接基于上面重映射后的 colorScheme 重建一套 media 版 textTheme,以
    // onSurface=ink 驱动各层级文字色,使任何走 DefaultTextStyle / Theme.textTheme
    // 的兜底文字在地域内都不再出现「白底白字」。应用的自定义排版走独立的
    // MusicFlowTypography 扩展(下一段已重映射),不受此替换影响。
    final TextTheme themedText =
        ThemeData(colorScheme: scheme, useMaterial3: true).textTheme;
    final Widget themed = Theme(
      data: parentTheme.copyWith(
        colorScheme: scheme,
        textTheme: themedText,
        scaffoldBackgroundColor: colors.canvas,
        canvasColor: colors.canvas,
        cardColor: colors.surface,
        dividerColor: colors.divider,
        extensions: extensions,
      ),
      child: child,
    );
    return themed;
  }
}

MusicFlowColors _mediaColors(
  MusicFlowColors parent,
  MusicFlowMediaVisuals visuals,
  MusicFlowMediaSurfaceRole role,
) {
  final (canvas, surface, raised) = switch (role) {
    MusicFlowMediaSurfaceRole.stage => (
      visuals.stageBase,
      visuals.stageBase,
      visuals.stageGlow,
    ),
    MusicFlowMediaSurfaceRole.mini => (
      visuals.miniSurface,
      visuals.miniSurface,
      visuals.panelSurface,
    ),
    MusicFlowMediaSurfaceRole.panel => (
      visuals.panelSurface,
      visuals.panelSurface,
      visuals.miniSurface,
    ),
  };
  final mediaSurfaces = <Color>[
    visuals.stageBase,
    visuals.stageGlow,
    visuals.stageBottom,
    visuals.miniSurface,
    visuals.panelSurface,
  ];
  final error = MusicFlowColors.ensureColorContrastAcross(
    parent.error,
    backgrounds: mediaSurfaces,
  );
  final warning = MusicFlowColors.ensureColorContrastAcross(
    parent.warning,
    backgrounds: mediaSurfaces,
  );
  final divider = MusicFlowColors.ensureColorContrastAcross(
    parent.divider,
    backgrounds: mediaSurfaces,
    minimumRatio: 3,
  );
  final onDisabled = MusicFlowColors.ensureColorContrastAcross(
    Color.lerp(visuals.mutedForeground, surface, 0.18)!,
    backgrounds: mediaSurfaces,
    minimumRatio: 3,
  );
  final onSurface = MusicFlowColors.readableOn(surface);
  // 文字用固定高对比前景(黑/白),不随封面主色调漂移,保证任何封面都清晰可读。
  // 歌手/辅助文字(muted)用同一前景按表面轻微融合以区分层级。
  final fixedMuted = Color.lerp(onSurface, surface, 0.22)!;
  // accent 既作背景(激活控件)也作前景(当前播放行标题/图标)。仅靠
  // readableOn 保证的 ink 不足以覆盖它:浅色专辑封面会把 controlAccent 和
  // 面板表面都拉近白,导致「白底白字」文案不可读。这里强制 accent 相对它所在
  // 的媒体表面(surface = panel/mini/stage)达到足够对比,前景随表面自动压深/提亮。
  final accent = MusicFlowColors.ensureColorContrast(
    visuals.controlAccent,
    background: surface,
  );
  final onAccent = MusicFlowColors.ensureColorContrast(
    MusicFlowColors.readableOn(accent),
    background: accent,
  );

  return parent.copyWith(
    accent: accent,
    onAccent: onAccent,
    contentTint: accent,
    onContentTint: onAccent,
    canvas: canvas,
    surface: surface,
    raised: raised,
    ink: onSurface,
    muted: fixedMuted,
    divider: divider,
    controlBoundary: accent,
    error: error,
    onError: MusicFlowColors.readableOn(error),
    warning: warning,
    onWarning: MusicFlowColors.readableOn(warning),
    disabled: raised,
    onDisabled: onDisabled,
  );
}

MusicFlowTypography _mediaTypography(MusicFlowTypography parent, MusicFlowColors colors) {
  return parent.copyWith(
    display: parent.display.copyWith(color: colors.ink),
    headline: parent.headline.copyWith(color: colors.ink),
    title: parent.title.copyWith(color: colors.ink),
    body: parent.body.copyWith(color: colors.ink),
    label: parent.label.copyWith(color: colors.ink),
    metadata: parent.metadata.copyWith(color: colors.muted),
  );
}
