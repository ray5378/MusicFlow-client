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
  });

  final String title;
  final String? description;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

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
          Expanded(child: text),
          if (action != null) ...<Widget>[
            SizedBox(width: context.musicFlowSpacing.sm),
            action,
          ],
        ],
      ),
    );
  }
}
