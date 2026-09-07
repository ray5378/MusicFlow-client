import 'package:flutter/material.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

class DiscoverSectionMessage extends StatelessWidget {
  const DiscoverSectionMessage({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    this.onRetry,
  });

  final String title;
  final String description;
  final IconData icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '$title，$description',
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ExcludeSemantics(
              child: SizedBox.square(
                dimension: context.musicFlowInteraction.minimumTouchTarget,
                child: Center(
                  child: Icon(icon, size: 24, color: context.musicFlowColors.muted),
                ),
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(title, style: context.musicFlowTypography.title),
                        SizedBox(height: context.musicFlowSpacing.xxs),
                        Text(
                          description,
                          style: context.musicFlowTypography.body.copyWith(
                            color: context.musicFlowColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onRetry != null) ...<Widget>[
                    SizedBox(height: context.musicFlowSpacing.xs),
                    MusicFlowButton.ghost(
                      label: loc.widgets_retry,
                      leadingIcon: AppIcons.refresh,
                      onPressed: onRetry,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

