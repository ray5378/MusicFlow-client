import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/features/discover/pages/search_page.dart';
import 'package:musicflow_client/features/library/pages/album_list_page.dart';
import 'package:musicflow_client/features/library/pages/artist_list_page.dart';
import 'package:musicflow_client/features/library/pages/playlist_search_page.dart';
import 'package:musicflow_client/features/library/pages/song_list_page.dart';
import 'package:musicflow_client/features/library/pages/starred_page.dart';
import 'package:musicflow_client/features/settings/pages/offline_cached_songs_page.dart';
import 'package:musicflow_client/features/study/pages/study_home_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/ui/nav_order_provider.dart';

/// 顶部分类导航条（可左右滑动，长按任意项可拖拽排序）。
///
/// 顺序持久化在本地（按平台各自保存），默认顺序：
/// 探索、喜欢、歌单、学习、歌曲、艺术家、专辑、已缓存。
class CategoryNavBar extends ConsumerWidget {
  const CategoryNavBar({super.key});

  static const double _itemWidth = 64;
  static const double _itemHeight = 64;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final order = ref.watch(navOrderProvider).valueOrNull?.category ??
        CategoryNavIds.defaults;
    final items = _items(loc);

    return Semantics(
      label: loc.discover_category_nav,
      child: SizedBox(
        height: _itemHeight + context.musicFlowSpacing.xs * 2,
        child: ReorderableListView.builder(
          scrollDirection: Axis.horizontal,
          buildDefaultDragHandles: false,
          // 条目很少(≤8)，一次性把屏外项也建出来：保持与旧版 Row 一致的
          // 可见性/语义树（读屏与 finder 都能拿到全部入口）。
          cacheExtent: 1200,
          padding: EdgeInsets.symmetric(
            horizontal: context.musicFlowPageHorizontalPadding - 5,
            vertical: context.musicFlowSpacing.xs,
          ),
          itemCount: order.length,
          onReorder: (oldIndex, newIndex) {
            unawaited(
              ref
                  .read(navOrderProvider.notifier)
                  .reorderCategory(oldIndex, newIndex),
            );
          },
          itemBuilder: (context, index) {
            final id = order[index];
            final item = items[id];
            if (item == null) {
              // 罕见：持久化数据含未知 id（normalize 已过滤，这里兜底）。
              return SizedBox(key: ValueKey<String>('category-nav-$id'));
            }
            return ReorderableDelayedDragStartListener(
              key: ValueKey<String>('category-nav-$id'),
              index: index,
              child: Padding(
                padding: EdgeInsets.only(right: context.musicFlowSpacing.md),
                child: _CategoryNavItem(
                  label: item.label,
                  icon: item.icon,
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MusicFlowPageRoute<void>(
                        context: context,
                        builder: (context) => item.page,
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// id → (文案, 图标, 页面)。顺序由 [navOrderProvider] 决定。
  static Map<String, ({String label, IconData icon, Widget page})> _items(
    AppLocalizations loc,
  ) {
    return <String, ({String label, IconData icon, Widget page})>{
      CategoryNavIds.explore: (
        label: loc.discover_explore,
        icon: AppIcons.search,
        page: const SearchPage(),
      ),
      CategoryNavIds.favorites: (
        label: loc.discover_category_favorites,
        icon: AppIcons.heart,
        page: const StarredPage(),
      ),
      CategoryNavIds.playlists: (
        label: loc.discover_category_playlists,
        icon: AppIcons.playlist,
        page: const PlaylistSearchPage(),
      ),
      CategoryNavIds.study: (
        label: loc.study_title,
        icon: AppIcons.study,
        page: const StudyHomePage(),
      ),
      CategoryNavIds.songs: (
        label: loc.discover_category_songs,
        icon: AppIcons.music,
        page: const SongListPage(),
      ),
      CategoryNavIds.artists: (
        label: loc.discover_category_artists,
        icon: AppIcons.profile,
        page: const ArtistListPage(),
      ),
      CategoryNavIds.albums: (
        label: loc.discover_category_albums,
        icon: AppIcons.album,
        page: const AlbumListPage(),
      ),
      CategoryNavIds.cached: (
        label: loc.offline_cache_cached_songs_title,
        icon: AppIcons.offline,
        page: const OfflineCachedSongsPage(),
      ),
    };
  }
}

class _CategoryNavItem extends StatelessWidget {
  const _CategoryNavItem({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: MusicFlowPressable(
        onPressed: onPressed,
        minimumSize: const Size(CategoryNavBar._itemWidth, 64),
        borderRadius: context.musicFlowRadii.surface,
        child: SizedBox(
          width: CategoryNavBar._itemWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 26, color: context.musicFlowColors.accent),
              SizedBox(height: context.musicFlowSpacing.xxs),
              Text(
                label,
                style: context.musicFlowTypography.metadata,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
