import 'package:flutter/material.dart';

import '../music_flow_context.dart';

class MusicFlowPageHeader extends StatelessWidget {
  const MusicFlowPageHeader({
    super.key,
    required this.title,
    this.description,
    this.leading,
    this.trailing,
    this.primaryAction,
    this.padding,
  });

  final String title;
  final String? description;
  final Widget? leading;
  final Widget? trailing;
  final Widget? primaryAction;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final spacing = context.musicFlowSpacing;
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          header: true,
          namesRoute: true,
          child: Text(title, style: context.musicFlowTypography.display),
        ),
        if (description != null) ...<Widget>[
          SizedBox(height: spacing.xxs),
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
      padding:
          padding ??
          EdgeInsets.fromLTRB(
            context.musicFlowPageHorizontalPadding,
            spacing.sm,
            context.musicFlowPageHorizontalPadding,
            spacing.sm,
          ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                if (leading != null) ...<Widget>[
                  leading!,
                  SizedBox(width: spacing.sm),
                ],
                Expanded(child: titleBlock),
                if (trailing != null) ...<Widget>[
                  SizedBox(width: spacing.sm),
                  trailing!,
                ],
              ],
            ),
          ),
          if (primaryAction != null) ...<Widget>[
            SizedBox(height: spacing.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: primaryAction!,
            ),
          ],
        ],
      ),
    );
  }
}
