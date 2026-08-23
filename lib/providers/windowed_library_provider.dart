import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/library/widgets/windowed_paginated_list.dart';
import '../data/models/album.dart';
import '../data/models/artist.dart';
import '../data/models/playlist.dart';
import '../data/models/song.dart';
import 'library_provider.dart';
import 'music_provider.dart';
import 'playlist_provider.dart';

/// 窗口化分页列表控制器(歌曲/专辑/艺术家/歌单)。
///
/// 全库长列表统一采用「服务端分页 + 虚拟滚动 + 视口渐进式加载」:
/// 渲染层只取视口窗口,数据层按 page/pageSize 分块拉取并剪枝
/// (见 WindowedPaginatedList / WindowedListView),禁止一次性全表加载。
final windowedSongsProvider =
    ChangeNotifierProvider.autoDispose<WindowedPaginatedList<Song>>((ref) {
  final repository = ref.watch(musicRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  final controller = WindowedPaginatedList<Song>(
    fetcher: (page, pageSize, query) async {
      if (repository == null || libraryId == null || libraryId.isEmpty) {
        return (items: <Song>[], total: 0);
      }
      return repository.getSongsPage(page, pageSize, query: query);
    },
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final windowedAlbumsProvider =
    ChangeNotifierProvider.autoDispose<WindowedPaginatedList<Album>>((ref) {
  final repository = ref.watch(musicRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  final controller = WindowedPaginatedList<Album>(
    fetcher: (page, pageSize, query) async {
      if (repository == null || libraryId == null || libraryId.isEmpty) {
        return (items: <Album>[], total: 0);
      }
      return repository.getAlbumsPage(page, pageSize, query: query);
    },
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final windowedArtistsProvider =
    ChangeNotifierProvider.autoDispose<WindowedPaginatedList<Artist>>((ref) {
  final repository = ref.watch(musicRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  final controller = WindowedPaginatedList<Artist>(
    fetcher: (page, pageSize, query) async {
      if (repository == null || libraryId == null || libraryId.isEmpty) {
        return (items: <Artist>[], total: 0);
      }
      return repository.getArtistsPage(page, pageSize, query: query);
    },
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final windowedPlaylistsProvider =
    ChangeNotifierProvider.autoDispose<WindowedPaginatedList<Playlist>>((
  ref,
) {
  final repository = ref.watch(playlistRepositoryProvider);
  final libraryId = ref.watch(activeLibraryProvider)?.id;
  final controller = WindowedPaginatedList<Playlist>(
    fetcher: (page, pageSize, query) async {
      if (repository == null || libraryId == null || libraryId.isEmpty) {
        return (items: <Playlist>[], total: 0);
      }
      return repository.getPlaylistsPage(page, pageSize, query: query);
    },
  );
  ref.onDispose(controller.dispose);
  return controller;
});
