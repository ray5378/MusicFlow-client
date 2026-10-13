import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/offline/offline_cache_daemon.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/features/discover/discover_page_support.dart';
import 'package:musicflow_client/features/discover/widgets/discover_playlist_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/discover_section_message.dart';
import 'package:musicflow_client/features/discover/widgets/hoverable_horizontal_scroll.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/playlist_options_sheet.dart';

/// 最近更新的歌单(横滑卡片行)
///
/// 从 `discover_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class RecentPlaylistsSection extends ConsumerWidget {
  const RecentPlaylistsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final playlistsAsync = ref.watch(recentPlaylistsProvider);
    final loadFailed = ref.watch(recentPlaylistsLoadFailedProvider);
    // 当前播放来源：识别正在播放的歌单（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);

    // 歌单封面在「展示」时即写离线缓存（非动态歌单），供首页断网离线展示；
    // 动态歌单（今日漫游/每日推荐等）由 cachePlaylistCover 内部判定跳过。
    ref.listen(recentPlaylistsProvider, (_, next) {
      final data = next.valueOrNull;
      if (data == null || data.isEmpty) return;
      final daemon = ref.read(offlineCacheDaemonProvider);
      for (final pl in data) {
        final cover = pl.coverArt?.trim() ?? '';
        if (cover.isEmpty) continue;
        unawaited(daemon.cachePlaylistCover(cover, playlistName: pl.name));
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader.compact(
          title: loc.discover_recent_playlists,
          // 刷新按钮挨着模块标题。
          trailingFollowsTitle: true,
          trailing: MusicFlowIconButton(
            icon: AppIcons.refresh,
            label: loc.discover_refresh_recent_playlists,
            onPressed: () => ref.invalidate(recentPlaylistsProvider),
          ),
        ),
        SizedBox(height: context.musicFlowSpacing.xxs),
        playlistsAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (playlists) {
            if (playlists.isEmpty) {
              // 数据驱动解耦:服务端暂无歌单数据时整块隐藏;仅加载失败才保留
              // 错误提示(可重试),避免空数据/失败占位堆满首屏。
              if (!loadFailed) return const SizedBox.shrink();
              return DiscoverSectionMessage(
                title: loc.discover_section_unavailable_playlist,
                description: loc.discover_error_desc_check_route,
                icon: AppIcons.cloudOff,
                onRetry: () => ref.invalidate(recentPlaylistsProvider),
              );
            }
            return HoverableHorizontalScroll(
              builder: (context, controller) => SizedBox(
                height: playlistRailHeight(context),
                child: ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
                  cacheExtent: 0,
                  padding: EdgeInsets.zero,
                  itemCount: playlists.length,
                  separatorBuilder: (context, index) =>
                      SizedBox(width: context.musicFlowSpacing.sm),
                  itemBuilder: (context, index) {
                    final pl = playlists[index];
                    return DiscoverPlaylistCard(
                      width: kPlaylistCardWidth,
                      title: pl.name,
                      subtitle: loc.discover_track_count('${pl.songCount}'),
                      coverArtId: pl.coverArt,
                      isNowPlaying: queueOrigin?.matchesPlaylist(pl.id) ??
                          false,
                      onLongPress: () => showPlaylistOptionsSheet(
                        context: context,
                        playlist: pl,
                      ),
                      onPlay: () => playLocalPlaylistById(
                            ref,
                            pl.id,
                            coverArtId: pl.coverArt,
                            playlistName: pl.name,
                          ),
                      onPressed: () {
                        Navigator.of(context).push<void>(
                          MusicFlowPageRoute<void>(
                            context: context,
                            builder: (context) => PlaylistDetailPage(
                              playlistId: pl.id,
                              initialName: pl.name,
                              initialSongCount: pl.songCount,
                              initialCoverArt: pl.coverArt,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            );
          },
          loading: () => SizedBox(
            height: playlistRailHeight(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: 4,
              separatorBuilder: (context, index) =>
                  SizedBox(width: context.musicFlowSpacing.sm),
              itemBuilder: (context, index) =>
                  DiscoverPlaylistCardLoading(width: kPlaylistCardWidth),
            ),
          ),
          error: (error, stackTrace) => DiscoverSectionMessage(
            title: loc.discover_recent_playlists_load_failed,
            description: loc.discover_error_desc_switch_route,
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(recentPlaylistsProvider),
          ),
        ),
      ],
    );
  }
}
