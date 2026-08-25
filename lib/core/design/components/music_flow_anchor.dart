import 'package:flutter/material.dart';

/// 最近一次点击(指针按下)的全局坐标。
///
/// 桌面端的「更多」类弹窗由 `VoidCallback` 触发,回调本身不带触发按钮的位置。
/// 通过根级 `Listener` 记录每次指针按下的全局位置,弹窗打开时以该点为锚点,
/// 在触发按钮附近渲染一个「非全局遮盖」的小弹窗(对齐 Windows 上下文菜单交互),
/// 而不再使用安卓式底部抽屉或全屏遮盖的居中对话框。
Offset? musicFlowLastTapGlobalPosition;

/// 根级指针位置捕获作用域。
///
/// 放在应用最外层,记录任意一次指针按下的全局坐标供锚点弹窗复用。
/// `Listener` 作为命中路径上的祖先节点,会接收所有落在其后代上的指针事件。
class MusicFlowTapAnchorScope extends StatelessWidget {
  const MusicFlowTapAnchorScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) =>
          musicFlowLastTapGlobalPosition = event.position,
      child: child,
    );
  }
}