import 'package:flutter/material.dart';

import '../core/design/music_flow_design.dart';
import '../l10n/generated/app_localizations.dart';

@immutable
class MusicFlowMediaAction {
  const MusicFlowMediaAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
}

/// Shared action hierarchy for albums, artists, and playlists.
///
/// Play and shuffle remain labeled primary actions. Lower-frequency actions
/// are rendered as a separate icon toolbar so they do not compete with the
/// main listening decision.
class MusicFlowMediaActions extends StatelessWidget {
  const MusicFlowMediaActions({
    super.key,
    required this.onPlay,
    this.onShuffle,
    this.showShuffle = false,
    this.playLabel,
    this.shuffleLabel,
    this.playIcon = AppIcons.play,
    this.shuffleIcon = AppIcons.shuffle,
    this.secondaryActions = const <MusicFlowMediaAction>[],
  });

  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  /// Keeps the shuffle action in the hierarchy when [onShuffle] is null.
  final bool showShuffle;
  final String? playLabel;
  final String? shuffleLabel;
  final IconData playIcon;
  final IconData shuffleIcon;
  final List<MusicFlowMediaAction> secondaryActions;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaledLabelSize = MediaQuery.textScalerOf(
          context,
        ).scale(context.musicFlowTypography.label.fontSize ?? 13);
        final stackPrimaryActions =
            constraints.maxWidth < 340 || scaledLabelSize >= 20;

        final resolvedPlayLabel = playLabel ?? loc.widgets_play;
        final resolvedShuffleLabel = shuffleLabel ?? loc.widgets_shuffle;

        final play = MusicFlowButton.primary(
          label: resolvedPlayLabel,
          semanticLabel: resolvedPlayLabel,
          leadingIcon: playIcon,
          onPressed: onPlay,
          expand: true,
          enableHaptics: true,
        );
        final shuffle = MusicFlowButton.secondary(
          label: resolvedShuffleLabel,
          semanticLabel: resolvedShuffleLabel,
          leadingIcon: shuffleIcon,
          onPressed: onShuffle,
          expand: true,
          enableHaptics: true,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!showShuffle && onShuffle == null)
              play
            else if (stackPrimaryActions) ...<Widget>[
              play,
              SizedBox(height: context.musicFlowSpacing.xs),
              shuffle,
            ] else
              Row(
                children: <Widget>[
                  Expanded(child: play),
                  SizedBox(width: context.musicFlowSpacing.sm),
                  Expanded(child: shuffle),
                ],
              ),
            if (secondaryActions.isNotEmpty) ...<Widget>[
              SizedBox(height: context.musicFlowSpacing.sm),
              Wrap(
                spacing: context.musicFlowSpacing.xs,
                runSpacing: context.musicFlowSpacing.xs,
                children: <Widget>[
                  for (final action in secondaryActions)
                    MusicFlowIconButton(
                      icon: action.icon,
                      label: action.label,
                      selected: action.selected,
                      onPressed: action.onPressed,
                      enableHaptics: true,
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}