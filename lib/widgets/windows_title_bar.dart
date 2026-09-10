import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// Windows runner 窗口控制通道(对应 windows/runner/flutter_window.cpp)。
const MethodChannel kWindowsWindowChannel = MethodChannel(
  'com.musicflow.app/window',
);

/// 是否为 Windows 桌面端。自绘标题栏、托盘/任务栏歌词仅在该平台生效。
bool get isWindowsDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Windows 窗口控制按钮区总宽度（最小化/最大化/关闭各 46px）。
///
/// 页面顶部若使用 [AppBar.actions]，在 Windows 桌面端需留出该宽度，
/// 避免自定义操作按钮与系统关闭/最大化/最小化按钮重叠。
const double kWindowsWindowControlsWidth = 46.0 * 3;

/// Windows 窗口控制按钮的高度（与 [WindowsWindowChrome] 覆盖层一致）。
const double kWindowsWindowControlsHeight = 40.0;

/// 系统窗口控制按钮的 key 前缀，供 CI 重叠检测排除自身。
const String kWindowControlButtonKeyPrefix = 'windows-window-control-';

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

/// 更新桌面歌词浮窗文本(空文本清空;原生层自适应大小重绘)。
Future<void> setDesktopLyricText(String text) async {
  if (!isWindowsDesktop) return;
  try {
    await kWindowsWindowChannel.invokeMethod<void>(
      'set_desktop_lyric_text',
      <String, Object>{'text': text},
    );
  } on MissingPluginException {
    // 非 Windows 平台没有对应原生实现,静默忽略。
  } on PlatformException {
    // 歌词更新失败不影响主流程。
  }
}

/// 推送桌面歌词浮窗完整显示状态(歌名/歌手/歌词行/播放/喜欢/模式/音量/
/// 歌词填充色)。原生层据此绘制两行文本与悬停控制按钮。
Future<void> setDesktopLyricState({
  required String song,
  required String artist,
  required String lyric,
  required bool playing,
  required bool liked,
  required String mode,
  required double volume,
  required int lyricColor,
}) async {
  if (!isWindowsDesktop) return;
  try {
    await kWindowsWindowChannel.invokeMethod<void>(
      'update_desktop_lyric_state',
      <String, Object>{
        'song': song,
        'artist': artist,
        'lyric': lyric,
        'playing': playing,
        'liked': liked,
        'mode': mode,
        'volume': volume,
        'lyricColor': lyricColor,
      },
    );
  } on MissingPluginException {
    // 非 Windows 平台没有对应原生实现,静默忽略。
  } on PlatformException {
    // 状态推送失败不影响主流程。
  }
}

/// 推送桌面歌词「播放队列」弹窗数据(已组好显示文本的行 + 当前曲下标)。
/// 行数与当前曲变化时全量推送,原生层据此绘制队列列表弹窗。
Future<void> setDesktopLyricQueue({
  required List<String> items,
  required int index,
}) async {
  if (!isWindowsDesktop) return;
  try {
    await kWindowsWindowChannel.invokeMethod<void>(
      'update_desktop_lyric_queue',
      <String, Object>{'items': items, 'index': index},
    );
  } on MissingPluginException {
    // 非 Windows 平台没有对应原生实现,静默忽略。
  } on PlatformException {
    // 队列推送失败不影响主流程。
  }
}

/// 推送桌面歌词「切换播放器」弹窗数据。
///
/// 桌面歌词浮窗的切换播放器按钮不再回到主窗口弹窗,而是在歌词窗**上方**
/// 展开自己的设备列表弹窗(内容与 MINI 播放条的小弹窗一致,2026-09-10 起)。
/// [items] 的元素形如
/// `{'title': 设备名, 'subtitle': 状态文案, 'current': bool}`;
/// [loading] 为 true 且列表为空时原生层显示「正在加载播放器…」。
Future<void> setDesktopLyricSwitchList({
  required List<Map<String, Object>> items,
  bool loading = false,
}) async {
  if (!isWindowsDesktop) return;
  try {
    await kWindowsWindowChannel.invokeMethod<void>(
      'update_desktop_lyric_switch_list',
      <String, Object>{'items': items, 'loading': loading},
    );
  } on MissingPluginException {
    // 非 Windows 平台没有对应原生实现,静默忽略。
  } on PlatformException {
    // 设备列表推送失败不影响主流程。
  }
}

/// 显示/隐藏桌面歌词浮窗(原生层置顶、不抢焦点)。
Future<void> setDesktopLyricVisible(bool visible) async {  if (!isWindowsDesktop) return;  try {
    await kWindowsWindowChannel.invokeMethod<void>(
      'set_desktop_lyric_visible',
      <String, Object>{'visible': visible},
    );
  } on MissingPluginException {
    // 非 Windows 平台没有对应原生实现,静默忽略。
  } on PlatformException {
    // 显隐失败不影响主流程。
  }
}

/// Windows 客户端无标题栏的顶部窗口控制覆盖层。
///
/// 去掉系统/自绘标题栏后，由本组件在窗口最顶上提供一个透明的拖拽区
/// (拖动移动窗口、双击最大化)，并在右上角无缝嵌入最小化/最大化/关闭
/// 按钮。仅 Windows 桌面端生效；安卓/Web 走系统窗口装饰。
///
/// **挂载位置是 MaterialApp.builder 层**（见 app.dart），即位于
/// Navigator / Overlay **之上**：任何页面、任何弹窗（切换播放器、
/// 发现新版本、锚点菜单……）打开时，顶部依旧可以拖动窗口。
/// 此前挂在 MainScaffold 内部，被模态路由整个盖住，
/// 表现为「打开弹窗后顶部无法拖动窗口」。
///
/// ⚠️ 正因为挂在这里，本组件**底下没有 Overlay 祖先**。而窗口控制按钮用了
/// `Tooltip`，`Tooltip` 显示时要 `Overlay.of(context)` —— 找不到就抛
/// **"No Overlay widget found."**，被 `ErrorWidget` 顶替后画成红框黄字
/// （2026-09-10 用户反馈「客户端右边一列奇怪英文」即此，实测已复现）。
///
/// 因此本组件**自带一个 `Overlay`**（见 build），把三个按钮放进自己的
/// Overlay 里：既保住「在最上层、弹窗盖不住」的既有行为，又让 Tooltip
/// 有 Overlay 可用。**不要为了省事把 Tooltip 去掉**——那是用户可见功能。
class WindowsWindowChrome extends StatelessWidget {
  const WindowsWindowChrome({super.key});

  // 与窗口控制按钮的高度一致(40)对齐,保证右上角按钮完整可见。
  static const double _height = 40;

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

    // 自带 Overlay:本组件位于 MaterialApp.builder 的 Stack 里、
    // Navigator/Overlay 之外,内部的 Tooltip 需要自己这层的 Overlay。
    // 直接挂 Overlay(而不是 SizedBox)即可——chrome 自身就用 Positioned
    // 定尺寸,Overlay 会把它当作整屏填充的子级正常布局。
    return Overlay(
      initialEntries: <OverlayEntry>[
        OverlayEntry(builder: _buildChrome),
      ],
    );
  }

  Widget _buildChrome(BuildContext context) {
    final loc = AppLocalizations.of(context);

    // 注意:这里返回的 `Positioned` 是 **OverlayEntry 的根** ——
    // Overlay(_Theater) 对根级 Positioned 有专门支持,会按 top/left/right
    // /height 精确定位这 40px 拖拽条;其余区域不占位、不拦事件。
    // 不要改成 Padding/Align —— 会失去「只覆盖顶部 40px」的命中语义,
    // 把整窗点击都吃掉。
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: _height,
      child: Stack(
        children: <Widget>[
          // 整条透明拖拽区:拖动移动窗口、双击最大化。
          //
          // 用 opaque 而非 translucent：本层已在所有弹窗之上，只有明确
          // 消费掉按下事件，才能保证「弹窗开着时顶部也能拖动窗口」。
          // 覆盖区仅 40px 高，且不遮挡任何弹窗的正文与按钮——
          // 弹窗顶部若正好有可点区域，其命中会先被本层吃掉，
          // 因此这里只保留拖拽/双击，不额外处理点击。
          Positioned.fill(
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => _invoke('start_move'),
                onDoubleTap: () => _invoke('maximize_toggle'),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          // 右上角窗口控制按钮,盖在拖拽区之上,始终可点。
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _WindowControlButton(
                  tooltip: loc.widgets_window_minimize,
                  icon: Icons.remove,
                  onPressed: () => _invoke('minimize'),
                ),
                _WindowControlButton(
                  tooltip: loc.widgets_window_maximize_restore,
                  icon: Icons.crop_square,
                  onPressed: () => _invoke('maximize_toggle'),
                ),
                _WindowControlButton(
                  tooltip: loc.widgets_window_close,
                  icon: Icons.close,
                  isClose: true,
                  onPressed: () => _invoke('close'),
                ),
              ],
            ),
          ),
        ],
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
          // 便于 CI 重叠检测排除系统窗口按钮自身。
          key: ValueKey<String>(
            '$kWindowControlButtonKeyPrefix${tooltip.hashCode}',
          ),
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