import 'package:flutter/material.dart';

import '../../../widgets/windows_title_bar.dart'
    show isWindowsDesktop, kWindowsWindowControlsWidth;

/// MusicFlow 通用 AppBar：在 Windows 桌面端自动为右上角窗口控制按钮
///（最小化/最大化/关闭，总宽 [kWindowsWindowControlsWidth]）留出空间，
/// 避免页面自己的操作按钮与系统关闭按钮重叠。
///
/// 非 Windows 平台或 actions 为空时行为与 Material [AppBar] 完全一致。
class MusicFlowAppBar extends StatelessWidget implements PreferredSizeWidget {
  const MusicFlowAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.bottom,
    this.toolbarHeight = kToolbarHeight,
    this.backgroundColor,
    this.foregroundColor,
    this.elevation,
    this.scrolledUnderElevation,
    this.centerTitle,
    this.titleSpacing,
    this.automaticallyImplyLeading = true,
  });

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final double toolbarHeight;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double? elevation;
  final double? scrolledUnderElevation;
  final bool? centerTitle;
  final double? titleSpacing;
  final bool automaticallyImplyLeading;

  @override
  Widget build(BuildContext context) {
    final effectiveActions =
        isWindowsDesktop && (actions?.isNotEmpty ?? false)
            ? <Widget>[...actions!, const SizedBox(width: kWindowsWindowControlsWidth)]
            : actions;

    return AppBar(
      title: title,
      actions: effectiveActions,
      leading: leading,
      bottom: bottom,
      toolbarHeight: toolbarHeight,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      elevation: elevation,
      scrolledUnderElevation: scrolledUnderElevation,
      centerTitle: centerTitle,
      titleSpacing: titleSpacing,
      automaticallyImplyLeading: automaticallyImplyLeading,
    );
  }

  @override
  Size get preferredSize => Size.fromHeight(
    toolbarHeight + (bottom?.preferredSize.height ?? 0),
  );
}
