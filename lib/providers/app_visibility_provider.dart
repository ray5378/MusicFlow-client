import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 应用/窗口是否处于「可见」状态。
///
/// 可见性 = 「窗口是否真的看不见」，而非「是否最前端」：
/// - `resumed`（前台激活）与 `inactive`（失焦——窗口仍在屏幕上，只是不在
///   最前端，用户仍能看见内容）→ **可见**，按实际可视区域动态渲染；
/// - `paused` / `hidden`（最小化、完全从屏幕消失）与 `detached`（销毁）→
///   **不可见**，冻结全部渲染。
/// Windows 与 Android 共享同一套 Dart 逻辑。
///
/// 双通道门控：
/// - 数据驱动部分（进度环、歌词行、列表行重建）由本 provider 冻结/恢复；
/// - Ticker 动画部分（黑胶旋转、跳动竖条、骨架屏 shimmer、滚动动画）
///   由 [AppVisibilityScope] 的 `TickerMode(enabled:)` 全局静音。
final appVisibilityProvider = StateProvider<bool>((ref) => true);

/// Windows 专属：主窗口是否被隐藏到托盘（SW_HIDE）。
///
/// Flutter 生命周期在 SW_HIDE 时不会可靠地降到 `paused/hidden`（窗口只是从
/// 屏幕消失、进程仍在后台播放），AppLifecycleState 仍可能停留 `inactive`/`resumed`
/// 导致按「失焦=可见」继续渲染。因此原生层通过 `com.musicflow.app/window-visible`
/// 通道主动告知一次可见性翻转，本 provider 作为第二道硬门控：
/// 窗口隐藏到托盘 → false 冻结全部渲染；从托盘恢复 → true。
final windowOccludedProvider = StateProvider<bool>((ref) => true);

/// 原生 → Dart 的窗口可见性通道（隐藏到托盘 / 从托盘恢复）。
const _windowVisibleChannel = BasicMessageChannel<String>(
  'com.musicflow.app/window-visible',
  StringCodec(),
);

/// 综合门控的真值来源：生命周期可见(inactive/resumed) **且** 主窗口未被
/// 隐藏到托盘([windowOccludedProvider])。
///
/// Ticker 动画由 [AppVisibilityScope] 用本 provider 全局静音；数据驱动部分
/// （[appVisibilityProvider] 的冻结进度/歌词等冻结 provider）也读取本 provider。
/// 这样「隐藏到托盘 → 冻结」与「最小化/销毁 → 冻结」走同一条真值链，避免
/// 只停 Ticker 却仍因数据驱动重建而持续调度帧。
final isRenderingActiveProvider = Provider<bool>(
  (ref) =>
      ref.watch(appVisibilityProvider) && ref.watch(windowOccludedProvider),
);

/// 挂在 [App] 外层：监听 AppLifecycleState 把可见性写入
/// [appVisibilityProvider]，并用 [TickerMode] 全局静音/恢复所有子级动画。
///
/// 失焦(inactive)窗口仍显示 → 保持可见、继续渲染（仅性能隔离，不整体停帧）；
/// 最小化(hidden/paused)、销毁(detached) → 冻结；恢复前台(resumed) → 可见。
class AppVisibilityScope extends ConsumerStatefulWidget {
  const AppVisibilityScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppVisibilityScope> createState() => _AppVisibilityScopeState();
}

class _AppVisibilityScopeState extends ConsumerState<AppVisibilityScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 原生层在「隐藏到托盘 / 从托盘恢复」时由 Native→Dart 主动上报窗口可见性，
    // 弥补 AppLifecycleState 对 SW_HIDE 不可靠的问题（隐藏窗口后若仍停留
    // inactive/resumed，会被误判为「失焦=可见」而继续渲染占 GPU）。
    _windowVisibleChannel.setMessageHandler((message) async {
      final visible = message == 'true';
      ref.read(windowOccludedProvider.notifier).state = visible;
      return null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 失焦(inactive)≠不可见：窗口仍在屏幕上、用户仍能看到内容，应继续按
    // 实际可视窗口动态渲染（性能靠组件层 RepaintBoundary 隔离，不整体停帧）。
    // 仅最小化/完全隐藏(paused、hidden)与销毁(detached)视为不可见并冻结。
    ref.read(appVisibilityProvider.notifier).state =
        state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
  }

  @override
  void dispose() {
    _windowVisibleChannel.setMessageHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 综合门控：生命周期可见 且 未被隐藏到托盘，任一为 false 都冻结全部渲染。
    final visible = ref.watch(isRenderingActiveProvider);
    return TickerMode(enabled: visible, child: widget.child);
  }
}
