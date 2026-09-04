import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/network/connectivity_monitor.dart';
import '../../../data/models/audio_quality.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/audio_quality_provider.dart';
import '../widgets/music_flow_settings_components.dart';

class AudioQualityPage extends ConsumerWidget {
  const AudioQualityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(audioQualitySettingsProvider);
    final networkType =
        ref.watch(currentNetworkTypeProvider).valueOrNull ?? NetworkType.none;
    final effectiveQuality = ref.watch(effectiveQualityProvider);
    final notifier = ref.read(audioQualitySettingsProvider.notifier);
    final loc = AppLocalizations.of(context);

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(context: context, title: loc.settings_audio_quality),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              context.musicFlowSpacing.md,
              context.musicFlowSpacing.sm,
              context.musicFlowSpacing.md,
              context.musicFlowSpacing.xxl + context.musicFlowShellBottomObstruction,
            ),
            children: <Widget>[
              MusicFlowSurface(
                level: MusicFlowSurfaceLevel.raised,
                borderColor: context.musicFlowColors.controlBoundary,
                padding: EdgeInsets.all(context.musicFlowSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(loc.settings_audio_current_strategy, style: context.musicFlowTypography.headline),
                    SizedBox(height: context.musicFlowSpacing.sm),
                    _StatusLine(
                      icon: _networkIcon(networkType),
                      label: loc.settings_audio_network,
                      value: _networkName(loc, networkType),
                    ),
                    SizedBox(height: context.musicFlowSpacing.xs),
                    _StatusLine(
                      icon: AppIcons.quality,
                      label: loc.settings_audio_effective_quality,
                      value: effectiveQuality.displayName,
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.musicFlowSpacing.xl),
              MusicFlowSettingsSection(
                title: loc.settings_audio_network_strategy,
                description: loc.settings_audio_network_strategy_desc,
                children: <Widget>[
                  MusicFlowToggleSettingRow(
                    icon: AppIcons.route,
                    title: loc.settings_audio_auto_switch,
                    description: settings.autoSwitch
                        ? loc.settings_audio_auto_switch_on_desc
                        : loc.settings_audio_auto_switch_off_desc,
                    value: settings.autoSwitch,
                    onChanged: notifier.setAutoSwitch,
                  ),
                ],
              ),
              SizedBox(height: context.musicFlowSpacing.xl),
              MusicFlowSettingsSection(
                title: settings.autoSwitch ? loc.settings_audio_wifi_section : loc.settings_audio_global_section,
                description: settings.autoSwitch
                    ? loc.settings_audio_wifi_section_desc
                    : loc.settings_audio_global_section_desc,
                children: <Widget>[
                  for (final quality in AudioQualityLevel.values)
                    MusicFlowChoiceRow(
                      title: quality.displayName,
                      description: _qualityDescription(loc, quality),
                      selected: settings.wifiQuality == quality,
                      onPressed: () => notifier.setWifiQuality(quality),
                      icon: AppIcons.quality,
                    ),
                ],
              ),
              if (settings.autoSwitch) ...<Widget>[
                SizedBox(height: context.musicFlowSpacing.xl),
                MusicFlowSettingsSection(
                  title: loc.settings_audio_mobile_section,
                  description: loc.settings_audio_mobile_section_desc,
                  children: <Widget>[
                    for (final quality in AudioQualityLevel.values)
                      MusicFlowChoiceRow(
                        title: quality.displayName,
                        description: _qualityDescription(loc, quality),
                        selected: settings.mobileQuality == quality,
                        onPressed: () => notifier.setMobileQuality(quality),
                        icon: AppIcons.signal,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Semantics(
      label: loc.settings_audio_status_line(label, value),
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox.square(
              dimension: context.musicFlowInteraction.minimumTouchTarget,
              child: Center(
                child: Icon(icon, size: 22, color: context.musicFlowColors.accent),
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: context.musicFlowTypography.metadata.copyWith(
                      color: context.musicFlowColors.muted,
                    ),
                  ),
                  SizedBox(height: context.musicFlowSpacing.xxs),
                  Text(value, style: context.musicFlowTypography.title),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _networkIcon(NetworkType type) => switch (type) {
  NetworkType.wifi => AppIcons.wifi,
  NetworkType.mobile => AppIcons.signal,
  NetworkType.none => AppIcons.wifiOff,
};

String _networkName(AppLocalizations loc, NetworkType type) => switch (type) {
  NetworkType.wifi => loc.settings_audio_network_wifi,
  NetworkType.mobile => loc.settings_audio_network_mobile,
  NetworkType.none => loc.settings_audio_network_none,
};

String _qualityDescription(AppLocalizations loc, AudioQualityLevel quality) => switch (quality) {
  AudioQualityLevel.original => loc.settings_audio_desc_original,
  AudioQualityLevel.high => loc.settings_audio_desc_high,
  AudioQualityLevel.standard => loc.settings_audio_desc_standard,
  AudioQualityLevel.dataSaver => loc.settings_audio_desc_data_saver,
};