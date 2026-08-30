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
  }) : _compact = false;

  /// 首页紧凑标题：字号比默认 headline 小一档（对齐箭头音乐首页模块标题）。
  const MusicFlowSectionHeader.compact({
    super.key,
    required this.title,
    this.description,
    this.actionLabel,
    this.onAction,
    this.trailing,
    this.padding = EdgeInsets.zero,
    this.trailingFollowsTitle = false,
  }) : _compact = true;

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

  final bool _compact;

  /// 首页紧凑标题行：刷新按钮的「图标」距标题最后一个字 15px（对齐箭头音乐
  /// 参考稿）。间距按可见图标字形计算，而非 48dp 触控盒边缘：
  /// MusicFlowIconButton = 48dp 盒内 22px 图标居中（两侧各 13px 不可见留白），
  /// 故盒间距 = 15 - (48 - 22) / 2 = 2px。
  static const double _titleToActionGap = 2;

  @override
  Widget build(BuildContext context) {
    final action =
        trailing ??
        (actionLabel == null
            ? null
            : MusicFlowButton.ghost(label: actionLabel!, onPressed: onAction));
    final titleStyle = _compact
        ? context.musicFlowTypography.title.copyWith(
            fontWeight: FontWeight.w700,
          )
        : context.musicFlowTypography.headline;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(title, style: titleStyle),
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
            // 标题不参与 flex 分配(按自然宽度布局),把剩余宽度全部让给下方
            // trailing 的 Expanded。此前用 Flexible(flex:1) 会与 Expanded(flex:1)
            // 平分剩余宽度,且 Flexible 是 loose、用不满自己那半,多余的宽度又
            // 不会再吐回给 Expanded,导致 trailing 只占约整个标题行一半——里面
            // 的 Spacer 只能把播放按钮推到行中部附近,正是首页「播放按钮一直
            // 自适应在页面中间」且多次改间距都无效的根因。
            Flexible(flex: 0, child: text)
          else
            Expanded(child: text),
          if (action != null) ...<Widget>[
            // 首页紧凑模式（compact + trailingFollowsTitle）下刷新按钮「图标」
            // 距标题最后一个字 15px（对齐箭头音乐参考稿，见 _titleToActionGap
            // 的换算说明）；其余场景保持既有间距。
            SizedBox(
              width: trailingFollowsTitle
                  ? _titleToActionGap
                  : context.musicFlowSpacing.sm,
            ),
            // trailing 若直接放进 Expanded，紧约束会把 MusicFlowIconButton
            // 整体拉宽到剩余空间，其内部 Center 会把图标「居中」到行中间
            // （最近更新歌单的刷新按钮曾因此浮在半路）。必须用 Align 把
            // trailing 左对齐：单个按钮保持 48dp 自然宽度紧贴标题；trailing
            // 为 Row 时内部 Row 仍占满宽度、Spacer 照常把播放按钮推到最右。
            if (trailingFollowsTitle)
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: action,
                ),
              )
            else
              action,
          ],
        ],
      ),
    );
  }
}
