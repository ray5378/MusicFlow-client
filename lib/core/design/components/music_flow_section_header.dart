import 'package:flutter/material.dart';

import '../music_flow_context.dart';
import 'music_flow_button.dart';

class MusicFlowSectionHeader extends StatelessWidget {
  const MusicFlowSectionHeader({
    super.key,
    required this.title,
    this.description,
    this.actionLabel,
    this.onAction,
    this.trailing,
    this.padding = EdgeInsets.zero,
    this.trailingFollowsTitle = false,
  });

  final String title;
  final String? description;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  /// 为 true 时标题不抢占剩余宽度,trailing 紧跟标题显示(首页「刷新」按钮
  /// 需挨着模块标题);trailing 内部可用 Spacer 把其余按钮推到最右。
  /// 默认 false,保持既有「trailing 靠右」行为,不影响其它使用方。
  final bool trailingFollowsTitle;

  @override
  Widget build(BuildContext context) {
    final action =
        trailing ??
        (actionLabel == null
            ? null
            : MusicFlowButton.ghost(label: actionLabel!, onPressed: onAction));
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(title, style: context.musicFlowTypography.headline),
        ),
        if (description != null) ...<Widget>[
          SizedBox(height: context.musicFlowSpacing.xxs),
          Text(
            description!,
            style: context.musicFlowTypography.body.copyWith(
              color: context.musicFlowColors.muted,
            ),
          ),
        ],
      ],
    );

    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (trailingFollowsTitle)
            Flexible(child: text)
          else
            Expanded(child: text),
          if (action != null) ...<Widget>[
            SizedBox(width: context.musicFlowSpacing.sm),
            if (trailingFollowsTitle) Expanded(child: action) else action,
          ],
        ],
      ),
    );
  }
}
