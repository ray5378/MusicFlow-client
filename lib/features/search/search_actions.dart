import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/search.dart';
import '../../data/repositories/search_repository.dart';
import '../../providers/effective_playback_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/search_provider.dart';
import '../../core/design/components/music_flow_message.dart';
import '../../core/utils/toast_notifier.dart';

void _toast(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  showMusicFlowToast(
    context,
    message,
    kind: error ? MusicFlowMessageKind.error : MusicFlowMessageKind.info,
  );
}

/// 后台监听入库任务:不阻塞任何 UI,完成后经全局 ToastNotifier 通知。
///
/// 提交成功后 fire-and-forget 调用;页面此时可能已被关闭/切换,
/// 因此完成通知走根导航器 Overlay(ToastNotifier)而不是页面 context。
void _watchImportTask(
  SearchRepository repo,
  String taskId,
  String label,
) {
  unawaited(
    repo.waitTask(taskId).then((result) {
      ToastNotifier.show('《$label》入库完成，可在音乐库查看');
    }).catchError((Object e) {
      ToastNotifier.show('《$label》入库失败: $e', kind: MusicFlowMessageKind.error);
    }),
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
  SearchSongLike item, {
  SearchPlaylist? playlist,
}) async {
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
            playlist ?? (item as SearchPlaylist),
          )
        : await repo.getCollectionSongs(kind, providerId, item);
    if (songs.isEmpty) {
      _toast(context, '该${_kindLabel(kind)}暂无可播放歌曲');
      return;
    }
    await playEffectiveQueue(ref, songs, startIndex: 0);
  } catch (e) {
    _toast(context, '播放失败: $e', error: true);
  }
}

/// 把远程歌曲加入本地库(触发即返回,后台监听完成)
Future<void> importSearchSong(
  BuildContext context,
  WidgetRef ref,
  SearchSong song,
) async {
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  try {
    final taskId = await repo.importSong(song.providerId, [song]);
    _toast(context, '已提交入库任务，完成后会通知你');
    _watchImportTask(repo, taskId, song.name);
  } catch (e) {
    _toast(context, '入库失败: $e', error: true);
  }
}

/// 把远程专辑加入本地库(以专辑歌单形式;触发即返回,后台监听完成)
Future<void> importSearchAlbum(
  BuildContext context,
  WidgetRef ref,
  SearchAlbum album,
) async {
  final repo = ref.read(searchRepositoryProvider);
  if (repo == null) return;
  try {
    final taskId = await repo.importAlbum(album.providerId, album);
    _toast(context, '已提交入库任务，完成后会通知你');
    _watchImportTask(repo, taskId, album.name);
  } catch (e) {
    _toast(context, '入库失败: $e', error: true);
  }
}

/// 把远程歌单加入本地库(**触发即返回,全程不阻塞 UI**)。
///
/// 只做一次 POST 提交(秒回),不弹任何等待遮罩;拉歌+入库由后端异步完成,
/// 期间用户可继续任何操作,完成后经全局 Toast 通知成功/失败。
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
    final taskId = await repo.startPlaylistImport(pl.providerId, pl);
    _toast(context, '《${pl.name}》入库任务已提交，完成后会通知你');
    _watchImportTask(repo, taskId, pl.name);
  } catch (e) {
    _toast(context, '入库失败: $e', error: true);
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
