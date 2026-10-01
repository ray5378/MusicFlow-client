import 'package:flutter/material.dart';

/// 首页「播放控制」整体块 —— **T01 占位版**，T02 会替换为真实实现
/// （固定高度盒 + Stack 分层：切换器 / Now 区 / 控制条 + 队列·音量覆盖面板）。
///
/// 为什么 T01 就要先放一个占位：T01 的产出是「分区自治注入 + 注册 + 文案」，
/// 但 `discover_page._homeSectionWidget()` 的 switch 必须现在就把 case 接上 ——
/// 该 switch 对未命中的 key 返回 null，分区会被直接跳过，等于注入白做。
///
/// 占位体用 `SizedBox.shrink()`（零高度）：不占首页任何空间，既不会扰动
/// 现有分区布局，也不会影响既有用例的取样；T02 换真实实现时只改本文件。
class RemoteControlSection extends StatelessWidget {
  const RemoteControlSection({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
