import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/design/music_flow_design.dart';

/// Windows runner 窗口控制通道(对应 windows/runner/flutter_window.cpp)。
const MethodChannel kWindowsWindowChannel = MethodChannel(
  'com.musicflow.app/window',
);

/// 是否为 Windows 桌面端。自绘标题栏、托盘/任务栏歌词仅在该平台生效。
bool get isWindowsDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// 把文本写入托盘图标 tooltip(空文本恢复默认应用名)。
Future<void> setTrayTooltip(String text) async {
  if (!isWindowsDesktop) return;
  try {
    await kWindowsWindowChannel.invokeMethod<void>(
      'set_tray_tooltip',
      <String, Object>{'text': text},
    );
  } on MissingPluginException {
    // 非 Windows 平台没有对应原生实现,静默忽略。
  } on PlatformException {
    // 托盘更新失败不影响主流程。
  }
}

/// Windows 客户端自绘标题栏。
///
/// 去掉系统标题栏(win32_window.cpp 剥离 WS_CAPTION)后,由本组件提供
/// 拖拽移动、双击最大化,以及最小化/最大化/关闭按钮(任务2)。
class WindowsTitleBar extends StatelessWidget {
  const WindowsTitleBar({super.key, this.title = 'MusicFlow'});

  final String title;

  Future<void> _invoke(String method) async {
    try {
      await kWindowsWindowChannel.invokeMethod<void>(method);
    } on MissingPluginException {
      // 非 Windows 平台没有对应原生实现,静默忽略。
    } on PlatformException {
      // 窗口控制失败不影响主流程。
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isWindowsDesktop) return const SizedBox.shrink();

    final colors = context.musicFlowColors;
    final spacing = context.musicFlowSpacing;
    final typography = context.musicFlowTypography;

    return Material(
      key: const ValueKey<String>('windows-title-bar'),
      color: colors.surface,
      child: SizedBox(
        height: 40,
        width: double.infinity,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 拖拽标题栏空白区域移动窗口;双击切换最大化/还原。
          onPanStart: (_) => _invoke('start_move'),
          onDoubleTap: () => _invoke('maximize_toggle'),
          child: Row(
            children: <Widget>[
              SizedBox(width: spacing.md),
              Icon(AppIcons.music, size: 16, color: colors.muted),
              SizedBox(width: spacing.xs),
              Text(
                title,
                style: typography.label.copyWith(color: colors.muted),
              ),
              const Spacer(),
              _WindowControlButton(
                tooltip: '最小化',
                icon: Icons.remove,
                onPressed: () => _invoke('minimize'),
              ),
              _WindowControlButton(
                tooltip: '最大化/还原',
                icon: Icons.crop_square,
                onPressed: () => _invoke('maximize_toggle'),
              ),
              _WindowControlButton(
                tooltip: '关闭',
                icon: Icons.close,
                isClose: true,
                onPressed: () => _invoke('close'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowControlButton extends StatelessWidget {
  const _WindowControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.isClose = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    return SizedBox(
      width: 46,
      height: 40,
      child: Tooltip(
        message: tooltip,
        child: MusicFlowPressable(
          onPressed: onPressed,
          borderRadius: BorderRadius.zero,
          minimumSize: Size.zero,
          hoverOverlayColor: isClose ? colors.error : colors.ink,
          pressedOverlayColor: isClose ? colors.error : colors.ink,
          child: Icon(
            icon,
            size: 18,
            color: isClose ? colors.error : colors.ink,
          ),
        ),
      ),
    );
  }
}
