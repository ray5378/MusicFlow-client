import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../music_flow_context.dart';
import 'music_flow_button.dart';

class MusicFlowEmptyState extends StatelessWidget {
  const MusicFlowEmptyState({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.all(32),
  });

  final String title;
  final String description;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: padding,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox.square(
                dimension: context.musicFlowInteraction.minimumTouchTarget,
                child: Center(
                  child: Icon(icon, size: 34, color: context.musicFlowColors.muted),
                ),
              ),
              SizedBox(height: context.musicFlowSpacing.md),
              Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: context.musicFlowTypography.headline,
                ),
              ),
              SizedBox(height: context.musicFlowSpacing.xs),
              Text(
                description,
                textAlign: TextAlign.center,
                style: context.musicFlowTypography.body.copyWith(
                  color: context.musicFlowColors.muted,
                ),
              ),
              if (actionLabel != null) ...<Widget>[
                SizedBox(height: context.musicFlowSpacing.lg),
                MusicFlowButton.secondary(label: actionLabel!, onPressed: onAction),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class MusicFlowErrorState extends StatelessWidget {
  const MusicFlowErrorState({
    super.key,
    required this.title,
    required this.description,
    this.icon = AppIcons.cloudOff,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.all(32),
  });

  final String title;
  final String description;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: padding,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox.square(
                dimension: context.musicFlowInteraction.minimumTouchTarget,
                child: Center(
                  child: Icon(icon, size: 34, color: context.musicFlowColors.error),
                ),
              ),
              SizedBox(height: context.musicFlowSpacing.md),
              Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: context.musicFlowTypography.headline,
                ),
              ),
              SizedBox(height: context.musicFlowSpacing.xs),
              Text(
                description,
                textAlign: TextAlign.center,
                style: context.musicFlowTypography.body.copyWith(
                  color: context.musicFlowColors.muted,
                ),
              ),
              if (actionLabel != null) ...<Widget>[
                SizedBox(height: context.musicFlowSpacing.lg),
                MusicFlowButton.secondary(label: actionLabel!, onPressed: onAction),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
