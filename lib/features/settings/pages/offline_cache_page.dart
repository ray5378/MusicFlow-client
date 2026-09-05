import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/offline/offline_cache_manager.dart';
import '../../../data/models/offline_cache_size.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/offline_cache_settings_provider.dart';
import '../../../providers/offline_provider.dart';
import '../widgets/music_flow_settings_components.dart';

/// 离线缓存设置页：总容量档位 + 占用展示 + 一键清空。
class OfflineCachePage extends ConsumerStatefulWidget {
  const OfflineCachePage({super.key});

  @override
  ConsumerState<OfflineCachePage> createState() => _OfflineCachePageState();
}

class _OfflineCachePageState extends ConsumerState<OfflineCachePage> {
  late OfflineCacheManager _cache;

  @override
  void initState() {
    super.initState();
    final manager = ref.read(offlineCacheManagerProvider);
    _cache = manager;
    ref
        .read(offlineCacheReadyProvider.future)
        .then((_) => _refresh());
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _clearCache() async {
    final loc = AppLocalizations.of(context);
    await _cache.clearAll();
    if (!mounted) return;
    _refresh();
    showMusicFlowMessage(
      context,
      loc.offline_cache_cleared,
      kind: MusicFlowMessageKind.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = ref.watch(offlineCacheSettingsProvider);
    final notifier = ref.read(offlineCacheSettingsProvider.notifier);
    final loc = AppLocalizations.of(context);
    final total = _cache.totalBytes;
    final counts = _cache.countByKind();

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(
        context: context,
        title: loc.offline_cache_title,
      ),
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
                    Text(
                      loc.offline_cache_usage,
                      style: context.musicFlowTypography.headline,
                    ),
                    SizedBox(height: context.musicFlowSpacing.sm),
                    _UsageLine(
                      icon: AppIcons.sdCard,
                      label: loc.offline_cache_used,
                      value: _formatBytes(total),
                    ),
                    SizedBox(height: context.musicFlowSpacing.xs),
                    _UsageLine(
                      icon: AppIcons.music,
                      label: loc.offline_cache_song,
                      value: '${counts[OfflineCacheKind.song] ?? 0}',
                    ),
                    _UsageLine(
                      icon: AppIcons.lyrics,
                      label: loc.offline_cache_lyric,
                      value: '${counts[OfflineCacheKind.lyric] ?? 0}',
                    ),
                    _UsageLine(
                      icon: AppIcons.image,
                      label: loc.offline_cache_cover,
                      value: '${counts[OfflineCacheKind.cover] ?? 0}',
                    ),
                    _UsageLine(
                      icon: AppIcons.playlist,
                      label: loc.offline_cache_playlist_cover,
                      value: '${counts[OfflineCacheKind.playlistCover] ?? 0}',
                      showBottomSpacing: false,
                    ),
                    SizedBox(height: context.musicFlowSpacing.lg),
                    MusicFlowButton.primary(
                      label: loc.offline_cache_clear,
                      leadingIcon: AppIcons.delete,
                      onPressed: total > 0 ? _clearCache : null,
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.musicFlowSpacing.xl),
              MusicFlowSettingsSection(
                title: loc.offline_cache_size_section,
                description: loc.offline_cache_size_section_desc,
                children: <Widget>[
                  for (final option in OfflineCacheSize.values)
                    MusicFlowChoiceRow(
                      title: option.displayName,
                      description: option == OfflineCacheSize.g2
                          ? loc.offline_cache_size_default
                          : option.displayName,
                      selected: size == option,
                      icon: AppIcons.sdCard,
                      onPressed: () => notifier.setSize(option),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UsageLine extends StatelessWidget {
  const _UsageLine({
    required this.icon,
    required this.label,
    required this.value,
    this.showBottomSpacing = true,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool showBottomSpacing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: showBottomSpacing ? 8 : 0),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: context.musicFlowColors.muted),
          SizedBox(width: context.musicFlowSpacing.sm),
          Expanded(
            child: Text(
              label,
              style: context.musicFlowTypography.body.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ),
          Text(value, style: context.musicFlowTypography.body),
        ],
      ),
    );
  }
}