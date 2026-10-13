import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/features/discover/discover_page_support.dart';
import 'package:musicflow_client/features/discover/widgets/discover_playlist_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/discover_section_message.dart';
import 'package:musicflow_client/features/discover/widgets/hoverable_horizontal_scroll.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/playlist_options_sheet.dart';

/// 本地随机分区标题:优先用后端透传的 subtag(如「每日更新」),缺省回落「平台推荐」。
/// 名称去掉末尾「音乐」与主项目前端保持一致。
String localChannelTitle(AppLocalizations loc, LocalRecommendChannel channel) {
  final base = channel.name.endsWith(loc.discover_music_suffix)
      ? channel.name.substring(0, channel.name.length - loc.discover_music_suffix.length)
      : channel.name;
  final tag = (channel.subtag != null && channel.subtag!.isNotEmpty)
      ? channel.subtag!
      : loc.discover_local_random;
  return '$base·$tag';
}

/// 平台推荐(按平台,原「本地随机」):由后端 /v1/local-recommend 提供,
/// 从本地库按平台随机挑歌单。歌单均已入库,点击直接打开本地歌单,无需导入刷新。
///
/// 从 `discover_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class LocalPlatformRecommendSection extends ConsumerWidget {
  const LocalPlatformRecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final channelsAsync = ref.watch(localRecommendChannelsProvider);
    final loadFailed = ref.watch(localRecommendChannelsLoadFailedProvider);
    // 当前播放来源：识别正在播放的歌单（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader.compact(title: loc.discover_local_random),
        SizedBox(height: context.musicFlowSpacing.xxs),
        channelsAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (channels) {
            final allPlaylists =
                channels.expand((c) => c.playlists).toList();
            if (allPlaylists.isEmpty) {
              // 数据驱动解耦:服务端暂无平台推荐数据时整块隐藏;仅加载失败才保留
              // 错误提示(可重试),避免空数据/失败占位堆满首屏。
              if (!loadFailed) return const SizedBox.shrink();
              return DiscoverSectionMessage(
                title: loc.discover_unavailable_local_random,
                description: loc.discover_error_desc_check_route,
                icon: AppIcons.cloudOff,
                onRetry: () => ref.invalidate(localRecommendChannelsProvider),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final channel in channels)
                  if (channel.playlists.isNotEmpty) ...<Widget>[
                    if (channels.length > 1) ...<Widget>[
                      SizedBox(height: context.musicFlowSpacing.sm),
                      // 分区标题优先用后端透传的 subtag(如「每日更新」),缺省回落「平台推荐」。
                      Text(
                        localChannelTitle(loc, channel),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.musicFlowTypography.label.copyWith(
                          color: context.musicFlowColors.accent,
                        ),
                      ),
                      // 有说明性 tagline 时作为副标题展示(缺省不显示)。
                      if (channel.tagline case final tagline?
                          when tagline.isNotEmpty) ...[
                        SizedBox(height: context.musicFlowSpacing.xxs),
                        Text(
                          tagline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.musicFlowTypography.metadata,
                        ),
                      ],
                      SizedBox(height: context.musicFlowSpacing.xxs),
                    ],
                    HoverableHorizontalScroll(
                      builder: (context, controller) => SizedBox(
                        height: playlistRailHeight(context),
                        child: ListView.separated(
                          controller: controller,
                          scrollDirection: Axis.horizontal,
                          // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
                          cacheExtent: 0,
                          padding: EdgeInsets.zero,
                          itemCount: channel.playlists.length,
                          separatorBuilder: (context, index) =>
                              SizedBox(width: context.musicFlowSpacing.sm),
                          itemBuilder: (context, index) {
                            final pl = channel.playlists[index];
                            return DiscoverPlaylistCard(
                              width: kPlaylistCardWidth,
                              title: pl.name,
                              subtitle: loc.discover_track_count('${pl.songCount}'),
                              coverArtId: pl.coverArt,
                              isNowPlaying:
                                  queueOrigin?.matchesPlaylist(pl.id) ??
                                  false,
                              onLongPress: () => showPlaylistOptionsSheet(
                                context: context,
                                playlist: Playlist(
                                  id: pl.id,
                                  name: pl.name,
                                  songCount: pl.songCount,
                                  coverArt: pl.coverArt,
                                  duration: 0,
                                ),
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
                    ),
                  ],
              ],
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
            title: loc.discover_local_random_load_failed,
            description: loc.discover_error_desc_switch_route,
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(localRecommendChannelsProvider),
          ),
        ),
      ],
    );
  }
}
