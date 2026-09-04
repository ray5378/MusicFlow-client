import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../data/models/provider_config.dart';
import '../../../data/sources/database/database_provider.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/lyrics_cover_provider.dart';
import '../widgets/music_flow_settings_components.dart';

class CoverProvidersPage extends ConsumerStatefulWidget {
  const CoverProvidersPage({super.key});

  @override
  ConsumerState<CoverProvidersPage> createState() => _CoverProvidersPageState();
}

class _CoverProvidersPageState extends ConsumerState<CoverProvidersPage> {
  @override
  Widget build(BuildContext context) {
    final configsAsync = ref.watch(coverProviderConfigsProvider);
    final loc = AppLocalizations.of(context);

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(context: context, title: loc.settings_cover_provider),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: configsAsync.when(
            data: _buildProviderList,
            loading: () => const MusicFlowProviderListSkeleton(),
            error: (error, stackTrace) => MusicFlowErrorState(
              title: loc.settings_cover_provider_page_error_title,
              description: loc.settings_cover_provider_page_error_desc('$error'),
              actionLabel: loc.widgets_retry,
              onAction: () => ref.invalidate(coverProviderConfigsProvider),
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
        title: loc.settings_cover_provider_empty_title,
        description: loc.settings_cover_provider_empty_desc,
        icon: AppIcons.image,
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
          description: loc.settings_cover_priority_desc,
        ),
      ),
      itemCount: currentConfigs.length,
      proxyDecorator: (child, index, animation) => child,
      onReorder: (oldIndex, newIndex) {
        if (oldIndex < newIndex) newIndex -= 1;
        final item = currentConfigs.removeAt(oldIndex);
        currentConfigs.insert(newIndex, item);

        final db = ref.read(appDatabaseProvider);
        updateCoverProviderOrder(db, currentConfigs);
        ref.invalidate(coverProviderConfigsProvider);
      },
      itemBuilder: (context, index) {
        final config = currentConfigs[index];
        return MusicFlowProviderSettingRow(
          key: ValueKey(config.id),
          index: index,
          title: _getProviderName(config.sourceId),
          description: _buildProviderSubtitle(config),
          enabled: config.enabled,
          onConfigure: _isConfigurable(config.sourceId)
              ? () => _openProviderConfigSheet(config)
              : null,
          onChanged: (value) {
            final db = ref.read(appDatabaseProvider);
            toggleCoverProvider(db, config.id, value);
            ref.invalidate(coverProviderConfigsProvider);
          },
        );
      },
    );
  }

  String _fanartApiKey(ProviderConfig config) {
    return (config.config?['apiKey'] as String? ?? '').trim();
  }

  bool _isConfigurable(String sourceId) => sourceId == 'fanart';

  String _buildProviderSubtitle(ProviderConfig config) {
    final loc = AppLocalizations.of(context);
    final description = _getProviderDescription(config.sourceId);
    if (config.sourceId != 'fanart') return description;

    final hasKey = _fanartApiKey(config).isNotEmpty;
    final status = hasKey
        ? loc.settings_cover_api_key_configured
        : loc.settings_cover_api_key_unconfigured;
    return '$description\n$status';
  }

  Future<void> _openProviderConfigSheet(ProviderConfig config) async {
    if (config.sourceId == 'fanart') await _editFanartApiKey(config);
  }

  Future<void> _editFanartApiKey(ProviderConfig config) async {
    final controller = TextEditingController(text: _fanartApiKey(config));
    final loc = AppLocalizations.of(context);
    final result = await showMusicFlowBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => AnimatedPadding(
        duration: sheetContext.musicFlowMotion.resolve(
          sheetContext,
          sheetContext.musicFlowMotion.state,
        ),
        curve: sheetContext.musicFlowMotion.easeOut,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: MusicFlowBottomSheet(
          title: loc.settings_configure_fanart,
          subtitle: loc.settings_configure_fanart_subtitle,
          constrainToAvailableHeight: true,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                MusicFlowTextField(
                  controller: controller,
                  label: loc.settings_api_key,
                  hintText: loc.settings_api_key_hint,
                  helperText: loc.settings_api_key_helper,
                  leadingIcon: AppIcons.key,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (value) =>
                      Navigator.of(sheetContext).pop(value.trim()),
                ),
                SizedBox(height: sheetContext.musicFlowSpacing.lg),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: sheetContext.musicFlowSpacing.xs,
                  runSpacing: sheetContext.musicFlowSpacing.xs,
                  children: <Widget>[
                    MusicFlowButton.ghost(
                      label: loc.settings_cancel,
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                    MusicFlowButton.secondary(
                      label: loc.settings_clear,
                      onPressed: () => Navigator.of(sheetContext).pop(''),
                    ),
                    MusicFlowButton.primary(
                      label: loc.settings_save,
                      onPressed: () => Navigator.of(
                        sheetContext,
                      ).pop(controller.text.trim()),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    controller.dispose();

    if (result == null) return;

    final db = ref.read(appDatabaseProvider);
    await updateCoverProviderConfig(db, config.id, {'apiKey': result});
    ref.invalidate(coverProviderConfigsProvider);
  }

  String _getProviderName(String sourceId) {
    final loc = AppLocalizations.of(context);
    switch (sourceId) {
      case 'subsonic':
        return loc.settings_provider_subsonic;
      case 'fanart':
        return 'Fanart.tv';
      case 'musicbrainz':
        return 'MusicBrainz';
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
        return loc.settings_cover_provider_subsonic_desc;
      case 'fanart':
        return loc.settings_cover_provider_fanart_desc;
      case 'musicbrainz':
        return 'MusicBrainz Cover Art Archive';
      case 'custom':
        return loc.settings_cover_provider_custom_desc;
      default:
        return '';
    }
  }
}