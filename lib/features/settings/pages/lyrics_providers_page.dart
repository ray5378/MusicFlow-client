import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/provider_config.dart';
import '../../../data/sources/database/database_provider.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/lyrics_cover_provider.dart';
import '../widgets/music_flow_settings_components.dart';

class LyricsProvidersPage extends ConsumerStatefulWidget {
  const LyricsProvidersPage({super.key});

  @override
  ConsumerState<LyricsProvidersPage> createState() =>
      _LyricsProvidersPageState();
}

class _LyricsProvidersPageState extends ConsumerState<LyricsProvidersPage> {
  @override
  Widget build(BuildContext context) {
    final configsAsync = ref.watch(lyricsProviderConfigsProvider);
    final loc = AppLocalizations.of(context);

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(context: context, title: loc.settings_lyrics_provider),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: configsAsync.when(
            data: _buildProviderList,
            loading: () => const MusicFlowProviderListSkeleton(),
            error: (error, stackTrace) => MusicFlowErrorState(
              title: loc.settings_lyrics_provider_page_error_title,
              description: loc.settings_lyrics_provider_page_error_desc('$error'),
              actionLabel: loc.widgets_retry,
              onAction: () => ref.invalidate(lyricsProviderConfigsProvider),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProviderList(List<ProviderConfig> configs) {
    final loc = AppLocalizations.of(context);
    if (configs.isEmpty) {
      return MusicFlowEmptyState(
        title: loc.settings_lyrics_provider_empty_title,
        description: loc.settings_lyrics_provider_empty_desc,
        icon: AppIcons.lyrics,
      );
    }

    final currentConfigs = List<ProviderConfig>.from(configs);

    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: EdgeInsets.fromLTRB(
        context.musicFlowSpacing.md,
        context.musicFlowSpacing.sm,
        context.musicFlowSpacing.md,
        context.musicFlowSpacing.xxl + context.musicFlowShellBottomObstruction,
      ),
      header: Padding(
        padding: EdgeInsets.only(bottom: context.musicFlowSpacing.md),
        child: MusicFlowSectionHeader(
          title: loc.settings_priority_order,
          description: loc.settings_lyrics_priority_desc,
        ),
      ),
      itemCount: currentConfigs.length,
      proxyDecorator: (child, index, animation) => child,
      onReorder: (oldIndex, newIndex) {
        if (oldIndex < newIndex) newIndex -= 1;
        final item = currentConfigs.removeAt(oldIndex);
        currentConfigs.insert(newIndex, item);

        final db = ref.read(appDatabaseProvider);
        updateLyricsProviderOrder(db, currentConfigs);
        ref.invalidate(lyricsProviderConfigsProvider);
      },
      itemBuilder: (context, index) {
        final config = currentConfigs[index];
        return MusicFlowProviderSettingRow(
          key: ValueKey(config.id),
          index: index,
          title: _getProviderName(config.sourceId),
          description: _getProviderDescription(config.sourceId),
          enabled: config.enabled,
          onChanged: (value) {
            final db = ref.read(appDatabaseProvider);
            toggleLyricsProvider(db, config.id, value);
            ref.invalidate(lyricsProviderConfigsProvider);
          },
        );
      },
    );
  }

  String _getProviderName(String sourceId) {
    final loc = AppLocalizations.of(context);
    switch (sourceId) {
      case 'subsonic':
        return loc.settings_provider_subsonic;
      case 'lrclib':
        return 'LRCLIB';
      case 'netease':
        return loc.settings_provider_netease;
      case 'custom':
        return loc.settings_provider_custom;
      default:
        return sourceId;
    }
  }

  String _getProviderDescription(String sourceId) {
    final loc = AppLocalizations.of(context);
    switch (sourceId) {
      case 'subsonic':
        return loc.settings_lyrics_provider_subsonic_desc;
      case 'lrclib':
        return loc.settings_lyrics_provider_lrclib_desc;
      case 'netease':
        return loc.settings_lyrics_provider_netease_desc;
      case 'custom':
        return loc.settings_lyrics_provider_custom_desc;
      default:
        return '';
    }
  }
}