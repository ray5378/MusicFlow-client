/// 主项目后端「播放器(peer)」模型 —— 对齐 /rest/api/v1/peers*。
library;

import 'song.dart';
class PeerInfo {
  const PeerInfo({
    required this.peerId,
    required this.name,
    required this.kind,
    required this.available,
    this.queueTotal = 0,
    this.queueActive = false,
  });

  factory PeerInfo.fromJson(Map<String, dynamic> j) => PeerInfo(
        peerId: '${j['peerId'] ?? ''}',
        name: (j['name'] ?? '').toString(),
        kind: (j['kind'] ?? '').toString(),
        available: j['available'] == true,
        queueTotal: (j['queue'] is Map<String, dynamic>)
            ? ((j['queue']['total'] as num?)?.toInt() ?? 0)
            : 0,
        queueActive: (j['queue'] is Map<String, dynamic>)
            ? (j['queue']['isActive'] == true)
            : false,
      );

  final String peerId;
  final String name;
  /// local / dlna / airplay / group
  final String kind;
  final bool available;
  final int queueTotal;
  final bool queueActive;

  bool get isLocal => kind == 'local';

  String get kindLabel => switch (kind) {
        'local' => '本机',
        'airplay' => 'AirPlay',
        'group' => '群组',
        _ => 'DLNA',
      };

  /// 队列摘要:`21 首 · 播放中`;空队列返回空串。
  String get queueLabel => queueTotal <= 0
      ? ''
      : '$queueTotal 首${queueActive ? ' · 播放中' : ''}';
}

/// 设备实时状态（GET /v1/peers/:id/status，dlna 为 SOAP 实时值）。
class PeerStatus {
  const PeerStatus({
    this.state = '',
    this.positionSeconds = 0,
    this.durationSeconds = 0,
    this.volume,
    this.muted = false,
    this.active = false,
  });

  factory PeerStatus.fromJson(Map<String, dynamic> j) => PeerStatus(
        state: (j['state'] ?? '').toString(),
        positionSeconds: (j['position'] as num?)?.toDouble() ?? 0,
        durationSeconds: (j['duration'] as num?)?.toDouble() ?? 0,
        volume: (j['volume'] as num?)?.toInt(),
        muted: j['muted'] == true,
        active: switch ((j['state'] ?? '').toString()) {
          'PLAYING' || 'PAUSED_PLAYBACK' || 'TRANSITIONING' => true,
          _ => false,
        },
      );

  final String state;
  final double positionSeconds;
  final double durationSeconds;
  final int? volume;
  final bool muted;
  final bool active;

  bool get playing => state == 'PLAYING';

  PeerStatus copyWith({
    String? state,
    double? positionSeconds,
    double? durationSeconds,
    int? volume,
    bool? muted,
    bool? active,
  }) {
    return PeerStatus(
      state: state ?? this.state,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
      active: active ?? this.active,
    );
  }
}

/// 队列条目：投递给后端 queue/play 的形状（对齐前端 songToQueueItem）。
Map<String, dynamic> songToQueueItem(dynamic song) => <String, dynamic>{
      'songId': song.id as String?,
      'title': (song.title as String?) ?? '未知',
      'artist': song.artist as String?,
      'album': song.album as String?,
      'albumId': song.albumId as String?,
      'mime': switch (((song.suffix as String?) ?? '').toLowerCase()) {
        'flac' => 'audio/flac',
        'wav' => 'audio/wav',
        'aac' => 'audio/aac',
        'ogg' => 'audio/ogg',
        'm4a' => 'audio/mp4',
        'opus' => 'audio/opus',
        'ape' => 'audio/ape',
        'wma' => 'audio/x-ms-wma',
        _ => 'audio/mpeg',
      },
      'coverArt': (song.coverArt as String?) ??
          ((song.albumId as String?) != null
              ? 'al-${song.albumId}'
              : null),
      'duration': (song.duration as num?)?.round(),
    };

/// 后端投屏队列条目 → 客户端 Song（对齐前端 queueItemToSong）。
/// 仅用于投屏队列面板展示，不参与本机播放。
Song castQueueItemToSong(Map<String, dynamic> it) {
  final songId = '${it['songId'] ?? ''}';
  final albumId = it['albumId'] as String?;
  return Song(
    id: songId,
    title: (it['title'] as String?) ?? '未知',
    artist: it['artist'] as String?,
    album: it['album'] as String?,
    albumId: albumId,
    duration: (it['duration'] as num?)?.toInt(),
    coverArt: (it['coverArt'] as String?) ?? (albumId != null ? 'al-$albumId' : null),
  );
}
