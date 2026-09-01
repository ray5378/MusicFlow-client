import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前播放队列的来源类型。
enum QueueOriginKind {
  playlist, // 歌单
  album, // 专辑
  artist, // 艺术家
  discover, // 首页随机
  search, // 搜索结果
  other,
}

/// 当前播放队列的来源（用于封面"正在播放"指示）。
class QueueOrigin {
  const QueueOrigin(this.kind, [this.id]);

  final QueueOriginKind kind;
  final String? id;

  bool get isPlaylist => kind == QueueOriginKind.playlist;
  bool get isAlbum => kind == QueueOriginKind.album;

  bool matchesPlaylist(String playlistId) =>
      isPlaylist && id == playlistId;

  bool matchesAlbum(String albumId) => isAlbum && id == albumId;

  @override
  String toString() => 'QueueOrigin(${kind.name}${id == null ? '' : ':$id'})';
}

/// 当前播放队列来源。每次发起播放时由 [QueueOriginScope] 写入；
/// 任何播放动作都会覆盖为对应来源（未指定则为 other，封面指示随之消失）。
final queueOriginProvider =
    StateProvider<QueueOrigin?>((ref) => null);

/// 便捷工具：将某次播放标记为指定来源。
void markQueueOrigin(WidgetRef ref, QueueOrigin origin) {
  ref.read(queueOriginProvider.notifier).state = origin;
}
