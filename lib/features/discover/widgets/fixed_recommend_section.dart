import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/offline/dynamic_cover_keys.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/features/discover/discover_page_support.dart';
import 'package:musicflow_client/features/discover/widgets/discover_playlist_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/discover_section_message.dart';
import 'package:musicflow_client/features/discover/widgets/hoverable_horizontal_scroll.dart';
import 'package:musicflow_client/features/library/pages/playlist_detail_page.dart';
import 'package:musicflow_client/features/library/widgets/playlist_options_sheet.dart';

/// 固定推荐歌单 + 随机歌单（对齐主项目首页「为你推荐」顶部）：
/// 固定卡（今日漫游/每日推荐/本地推荐，>30 首门槛）+ 随机补位的本地歌单，
/// 合计 homeCount 张（每日推荐插件配置，默认 8，含今日漫游固定卡）。
///
/// 从 `discover_page.dart` 抽出（v5.8.4 大页面拆分子组件，行为零变更）。
class FixedRecommendSection extends ConsumerWidget {
  const FixedRecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final sectionAsync = ref.watch(homeRecommendSectionProvider);
    final loadFailed = ref.watch(homeCardsLoadFailedProvider);
    // 当前播放来源：识别正在播放的歌单（封面叠加跳动竖条）。
    final queueOrigin = ref.watch(queueOriginProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MusicFlowSectionHeader.compact(
          title: loc.discover_for_you,
        ),
        SizedBox(height: context.musicFlowSpacing.xxs),
        sectionAsync.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          data: (section) {
            if (section.isEmpty) {
              // 数据驱动解耦:服务端暂无推荐歌单时整块隐藏;仅加载失败才保留
              // 错误提示(可重试),不让空数据/占位堆满首屏。
              if (!loadFailed) return const SizedBox.shrink();
              return DiscoverSectionMessage(
                title: loc.discover_unavailable_recommend,
                description: loc.discover_error_desc_check_route,
                icon: AppIcons.cloudOff,
                onRetry: () => ref.invalidate(homeRecommendSectionProvider),
              );
            }
            // 固定卡 + 随机歌单合并为横向卡片行，样式与「插件推荐」完全一致：
            // 152 宽封面、playlistRailHeight 行高、HoverableHorizontalScroll 左右滑动。
            final cards = <({String id, String name, String coverArt, int songCount, String playlistId})>[
              for (final c in section.fixed)
                (
                  id: c.playlistId,
                  name: c.playlistName.isNotEmpty ? c.playlistName : c.name,
                  coverArt: c.coverArt ?? '',
                  songCount: c.songCount,
                  playlistId: c.playlistId,
                ),
              for (final p in section.random)
                (
                  id: p.id,
                  name: p.name,
                  coverArt: p.coverArt ?? '',
                  songCount: p.songCount,
                  playlistId: p.id,
                ),
            ];
            return HoverableHorizontalScroll(
              builder: (context, controller) => SizedBox(
                height: playlistRailHeight(context),
                child: ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  // 严格视口渲染：只为视口内的封面构建/加载，不为视口外预热。
                  cacheExtent: 0,
                  padding: EdgeInsets.zero,
                  itemCount: cards.length,
                  separatorBuilder: (context, index) =>
                      SizedBox(width: context.musicFlowSpacing.sm),
                  itemBuilder: (context, index) {
                    final card = cards[index];
                    return DiscoverPlaylistCard(
                      width: kPlaylistCardWidth,
                      title: card.name,
                      subtitle: loc.discover_track_count('${card.songCount}'),
                      coverArtId: card.coverArt,
                      isNowPlaying:
                          queueOrigin?.matchesPlaylist(card.playlistId) ??
                          false,
                      // 动态歌单封面每日变化：不读不写离线缓存，冷启动每次重拉。
                      alwaysFresh:
                          DynamicCoverKeys.isDynamicPlaylist(
                            card.name,
                            id: card.playlistId,
                          ),
                      onLongPress: () => showPlaylistOptionsSheet(
                        context: context,
                        playlist: Playlist(
                          id: card.playlistId,
                          name: card.name,
                          songCount: card.songCount,
                          coverArt: card.coverArt,
                          duration: 0,
                        ),
                      ),
                      onPlay: () => playLocalPlaylistById(
                            ref,
                            card.playlistId,
                            coverArtId: card.coverArt,
                            playlistName: card.name,
                          ),
                      onPressed: () {
                        Navigator.of(context).push<void>(
                          MusicFlowPageRoute<void>(
                            context: context,
                            builder: (context) => PlaylistDetailPage(
                              playlistId: card.playlistId,
                              initialName: card.name,
                              initialSongCount: card.songCount,
                              initialCoverArt: card.coverArt,
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
            title: loc.discover_recommend_load_failed,
            description: loc.discover_error_desc_switch_route,
            icon: AppIcons.cloudOff,
            onRetry: () => ref.invalidate(homeRecommendSectionProvider),
          ),
        ),
      ],
    );
  }
}
