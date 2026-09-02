import 'package:flutter/material.dart';
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = ref.watch(appVisibilityProvider);
    return TickerMode(enabled: visible, child: widget.child);
  }
}
