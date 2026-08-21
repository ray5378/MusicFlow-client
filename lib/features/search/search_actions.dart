import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/search.dart';
import '../../data/repositories/search_repository.dart';
import '../../providers/player_provider.dart';
import '../../providers/search_provider.dart';
import '../../core/design/components/echo_page_route.dart';
import '../../features/library/pages/playlist_detail_page.dart';

void _toast(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.redAccent : null,
    ),
  );
}

/// 直接播放一首远程搜索歌曲(走 /rest/stream-remote)
Future<void> playRemoteSearchSong(
  BuildContext context,
  WidgetRef ref,
  SearchSong song,
) async {
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  try {
    final playSong = repo.buildRemoteSong(song);
    await ref.read(playerProvider.notifier).playPreviewSong(playSong);
  } catch (e) {
    _toast(context, '播放失败: $e', error: true);
  }
}

/// 拉取远程专辑/艺术家/歌单内部歌曲并直接播放
Future<void> playRemoteSearchCollection(
  BuildContext context,
  WidgetRef ref,
  SearchEntityKind kind,
  String providerId,
  SearchSongLike item,
) async {
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  if (providerId.isEmpty) {
    _toast(context, '未指定来源插件', error: true);
    return;
  }
  try {
    final songs = kind == SearchEntityKind.playlist
        ? await repo.getPlaylistSongs(
            providerId,
            item as SearchPlaylist,
          )
        : await repo.getCollectionSongs(kind, providerId, item);
    if (songs.isEmpty) {
      _toast(context, '该${_kindLabel(kind)}暂无可播放歌曲');
      return;
    }
    await ref.read(playerProvider.notifier).playQueue(songs, startIndex: 0);
  } catch (e) {
    _toast(context, '播放失败: $e', error: true);
  }
}

/// 把远程歌曲加入本地库(异步任务)
Future<void> importSearchSong(
  BuildContext context,
  WidgetRef ref,
  SearchSong song,
) async {
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  try {
    await repo.importSong(song.providerId, [song]);
    _toast(context, '已提交入库任务，稍候可在音乐库查看');
  } catch (e) {
    _toast(context, '入库失败: $e', error: true);
  }
}

/// 把远程专辑加入本地库(以专辑歌单形式)
Future<void> importSearchAlbum(
  BuildContext context,
  WidgetRef ref,
  SearchAlbum album,
) async {
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  try {
    await repo.importAlbum(album.providerId, album);
    _toast(context, '已提交入库任务，稍候可在音乐库查看');
  } catch (e) {
    _toast(context, '入库失败: $e', error: true);
  }
}

/// 导入远程歌单到本地库,返回 library playlistId 后打开
Future<void> importSearchPlaylist(
  BuildContext context,
  WidgetRef ref,
  SearchPlaylist pl,
) async {
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  if (pl.providerId.isEmpty) {
    _toast(context, '未指定来源插件', error: true);
    return;
  }
  try {
    final playlistId = await repo.importPlaylist(pl.providerId, pl);
    if (!context.mounted) return;
    Navigator.of(context).push<void>(
      EchoPageRoute<void>(
        context: context,
        builder: (context) => PlaylistDetailPage(playlistId: playlistId),
      ),
    );
  } catch (e) {
    _toast(context, '导入失败: $e', error: true);
  }
}

String _kindLabel(SearchEntityKind kind) {
  switch (kind) {
    case SearchEntityKind.song:
      return '歌曲';
    case SearchEntityKind.album:
      return '专辑';
    case SearchEntityKind.artist:
      return '艺术家';
    case SearchEntityKind.playlist:
      return '歌单';
  }
}
