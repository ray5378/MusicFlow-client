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

/// 来源类型 → 服务端 `POST /v1/play` 的 content type。
///
/// 服务端 `resolveContentSongs(type, id)` 能自行从库里解析出队列的只有
/// playlist / album / artist（外加 song / genre）；discover 是首页随机拼装、
/// search 是搜索结果快照、other 是本地任意队列，**服务端无从解析**，
/// 这些返回 null → 只能走整队推送兜底通道。
extension QueueOriginKindServerType on QueueOriginKind {
  String? get serverContentType => switch (this) {
        QueueOriginKind.playlist => 'playlist',
        QueueOriginKind.album => 'album',
        QueueOriginKind.artist => 'artist',
        _ => null,
      };
}

/// 当前播放队列的来源（用于封面"正在播放"指示）。
class QueueOrigin {
  const QueueOrigin(this.kind, [this.id]);

  final QueueOriginKind kind;
  final String? id;

  bool get isPlaylist => kind == QueueOriginKind.playlist;
  bool get isAlbum => kind == QueueOriginKind.album;

  /// 服务端 `POST /v1/play` 可直接解析的 content type。
  /// id 缺失或来源类型服务端无从解析（首页随机/搜索/其它）时为 null，
  /// 调用方据此回落到「整队推送」兜底通道。
  String? get serverContentType =>
      (id == null || id!.isEmpty) ? null : kind.serverContentType;

  bool matchesPlaylist(String playlistId) =>
      isPlaylist && id == playlistId;

  bool matchesAlbum(String albumId) => isAlbum && id == albumId;

  /// 序列化为可落盘的 Map（播放会话持久化用；见 player_playback_session）。
  ///
  /// 为什么必须持久化来源：重启 App 后队列由 `playback_session_v1` 恢复，
  /// 但恢复路径直接调 `playSong` 而非 [QueueOriginScope]，若不落盘则来源丢失
  /// → `pushLocalToPeer` 拿不到 serverContentType，大歌单被迫整队推送
  /// （MB 级上行，耗时随规模线性劣化）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.name,
        if (id != null && id!.isNotEmpty) 'id': id,
      };

  /// 从会话 payload 反序列化；字段缺失/类型不符/枚举名未知一律返回 null，
  /// 调用方按「其它来源」处理（安全降级为整队推送，不会误走主通道）。
  static QueueOrigin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kindName = raw['kind'];
    if (kindName is! String) return null;
    for (final kind in QueueOriginKind.values) {
      if (kind.name == kindName) {
        final id = raw['id'];
        return QueueOrigin(kind, id is String ? id : null);
      }
    }
    return null;
  }

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
