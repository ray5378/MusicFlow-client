import 'package:flutter/material.dart';

import 'tokens/music_flow_breakpoints.dart';
import 'tokens/music_flow_colors.dart';
import 'tokens/music_flow_interaction.dart';
import 'tokens/music_flow_motion.dart';
import 'tokens/music_flow_radii.dart';
import 'tokens/music_flow_spacing.dart';
import 'tokens/music_flow_typography.dart';

/// Typed access to Echo's semantic design vocabulary.
extension MusicFlowDesignContext on BuildContext {
  MusicFlowColors get musicFlowColors {
    final theme = Theme.of(this);
    return theme.extension<MusicFlowColors>() ??
        (theme.brightness == Brightness.dark
            ? MusicFlowColors.dark()
            : MusicFlowColors.light());
  }

  MusicFlowTypography get musicFlowTypography {
    return Theme.of(this).extension<MusicFlowTypography>() ??
        MusicFlowTypography.standard(musicFlowColors);
  }

  MusicFlowSpacing get musicFlowSpacing {
    return Theme.of(this).extension<MusicFlowSpacing>() ?? MusicFlowSpacing.standard;
  }

  MusicFlowRadii get musicFlowRadii {
    return Theme.of(this).extension<MusicFlowRadii>() ?? MusicFlowRadii.standard;
  }

  MusicFlowMotion get musicFlowMotion {
    return Theme.of(this).extension<MusicFlowMotion>() ?? MusicFlowMotion.standard;
  }

  MusicFlowInteraction get musicFlowInteraction {
    return Theme.of(this).extension<MusicFlowInteraction>() ??
        MusicFlowInteraction.standard;
  }

  MusicFlowBreakpoints get musicFlowBreakpoints {
    return Theme.of(this).extension<MusicFlowBreakpoints>() ??
        MusicFlowBreakpoints.standard;
  }

  bool get musicFlowReduceMotion {
    final mediaQuery = MediaQuery.maybeOf(this);
    return mediaQuery?.disableAnimations ??
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations;
  }

  MusicFlowWindowClass get musicFlowWindowClass {
    final width = MediaQuery.maybeSizeOf(this)?.width ?? 0;
    return musicFlowBreakpoints.classify(width);
  }

  double get musicFlowPageHorizontalPadding {
    return switch (musicFlowWindowClass) {
      MusicFlowWindowClass.compact => musicFlowSpacing.md,
      MusicFlowWindowClass.medium => musicFlowSpacing.lg,
      MusicFlowWindowClass.expanded => musicFlowSpacing.xl,
    };
  }
}
