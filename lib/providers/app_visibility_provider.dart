import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 应用/窗口是否处于「可见且可交互」状态。
///
/// 覆盖用户确认的「关闭主窗口」语义：最小化 / 失焦 / 切走 / 后台等窗口
/// 不可见场景一律视为不可见，仅 `resumed`（前台可见可交互）视为可见。
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
/// 失焦(inactive)、最小化(hidden/paused)、销毁(detached) → 不可见；
/// 恢复前台(resumed) → 可见。
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
    ref.read(appVisibilityProvider.notifier).state =
        state == AppLifecycleState.resumed;
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
