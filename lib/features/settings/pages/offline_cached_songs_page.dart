import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/offline/offline_cache_manager.dart';
import '../../../data/models/song.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/effective_playback_provider.dart';
import '../../../providers/offline_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../providers/queue_origin_provider.dart';
import '../../../widgets/song_list_item.dart';

/// 「已缓存音乐」页：按歌单样式展示离线缓存的歌曲，支持逐首播放与「全部播放」。
class OfflineCachedSongsPage extends ConsumerStatefulWidget {
  const OfflineCachedSongsPage({super.key});

  @override
  ConsumerState<OfflineCachedSongsPage> createState() =>
      _OfflineCachedSongsPageState();
}

class _OfflineCachedSongsPageState extends ConsumerState<OfflineCachedSongsPage> {
  List<CachedSongInfo> _songs = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
    // 播放新的歌曲会触发后台缓存新增条目，切歌时刷新列表。
    ref.listen<PlayerState>(playerProvider, (_, next) {
      if (next.currentSong?.id != null) _reload();
    });
  }

  Future<void> _reload() async {
    await ref.read(offlineCacheReadyProvider.future);
    if (!mounted) return;
    final cache = ref.read(offlineCacheManagerProvider);
    setState(() {
      _songs = cache.cachedSongs;
      _loaded = true;
    });
  }

  List<Song> _toSongs() => [
        for (final info in _songs)
          Song(
            id: info.songId,
            title: info.title,
            artist: info.artist.isEmpty ? null : info.artist,
            album: info.album,
            coverArt: info.coverArt,
            duration: info.durationSeconds,
            starred: false,
          ),
      ];

  Future<void> _playAll() async {
    final songs = _toSongs();
    if (songs.isEmpty) return;
    await playEffectiveQueue(
      ref,
      songs,
      origin: const QueueOrigin(QueueOriginKind.other),
    );
  }

  Future<void> _playAt(int index) async {
    final songs = _toSongs();
    if (songs.isEmpty || index >= songs.length) return;
    await playEffectiveQueue(
      ref,
      songs,
      startIndex: index,
      origin: const QueueOrigin(QueueOriginKind.other),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final totalBytes = _songs.fold<int>(0, (sum, s) => sum + s.size);
    final count = _songs.length;
    final currentSongId = ref.watch(
      playerProvider.select((s) => s.currentSong?.id),
    );

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(
        context: context,
        title: loc.offline_cache_cached_songs_title,
        subtitle: count == 0 ? null : loc.offline_cache_song_subtitle(count, _formatBytes(totalBytes)),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _songs.isEmpty
              ? _buildEmpty(loc)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: _songs.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) return _buildPlayAllHeader(loc, totalBytes);
                    final info = _songs[index - 1];
                    return MusicFlowSongRow(
                      song: _toSongs()[index - 1],
                      index: index,
                      isCurrent: info.songId == currentSongId,
                      onPressed: () => unawaited(_playAt(index - 1)),
                      onMorePressed: null,
                      showMoreButton: false,
                    );
                  },
                ),
    );
  }

  Widget _buildPlayAllHeader(AppLocalizations loc, int totalBytes) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        4,
        16,
        MediaQuery.paddingOf(context).bottom > 0 ? 8 : 4,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              loc.offline_cache_song_count(_songs.length),
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ),
          MusicFlowButton.primary(
            label: loc.library_play_all,
            leadingIcon: AppIcons.play,
            onPressed: _songs.isEmpty ? null : () => unawaited(_playAll()),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(AppLocalizations loc) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              AppIcons.offline,
              size: 56,
              color: context.musicFlowColors.muted,
            ),
            SizedBox(height: context.musicFlowSpacing.md),
            Text(
              loc.offline_cache_cached_songs_empty,
              textAlign: TextAlign.center,
              style: context.musicFlowTypography.metadata.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}