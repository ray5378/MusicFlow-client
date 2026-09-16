/// 主项目后端「播放器(peer)」模型 —— 对齐 /rest/api/v1/peers*。
library;

import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';

class PeerInfo {
  const PeerInfo({
    required this.peerId,
    required this.name,
    required this.kind,
    required this.available,
    this.self = false,
    this.platform,
    this.queueTotal = 0,
    this.queueActive = false,
  });

  factory PeerInfo.fromJson(Map<String, dynamic> j) => PeerInfo(
        peerId: '${j['peerId'] ?? ''}',
        name: (j['name'] ?? '').toString(),
        kind: (j['kind'] ?? '').toString(),
        available: j['available'] == true,
        // 服务端只给「发起本次请求的那个实例」那行打 self —— 客户端因此无需知道
        // 自己的实例键,靠它区分「我这条」与「同账号的其它播放端」。
        self: j['self'] == true,
        platform: (j['platform'] as String?)?.trim().isEmpty == true
            ? null
            : j['platform'] as String?,
        // 注意:`GET /rest/api/v1/peers`(列表)返回的 queue **没有 total 字段**,
        // 只有 items 数组(实测 2026-09-10:主卧 3246 首,queue.total 为 undefined);
        // 而 `GET /rest/api/v1/peers/:id/queue`(单设备)**有 total**。
        // 所以必须 fallback 到 items.length —— 只认 total 会让列表来源的
        // queueTotal 恒为 0,连带 canPull/queueLabel 全部失效
        // (桌面歌词设备行的 ↓ 箭头因此永远不亮)。
        queueTotal: (j['queue'] is Map<String, dynamic>)
            ? ((j['queue']['total'] as num?)?.toInt() ??
                (j['queue']['items'] as List<dynamic>?)?.length ??
                0)
            : 0,
        queueActive: (j['queue'] is Map<String, dynamic>)
            ? (j['queue']['isActive'] == true)
            : false,
      );

  final String peerId;
  final String name;
  /// local / dlna / airplay / group / sendspin
  final String kind;
  final bool available;

  /// 是否是「本端自己那条」local 行(服务端按请求方实例键打标)。
  final bool self;

  /// 设备名片里的平台(本机 peer 才有):web / windows / android / ios / macos …
  /// 本机实例统一标为「客户端」;服务端与请求方实例键对齐,不再单列「Web 播放器」。
  final String? platform;
  final int queueTotal;
  final bool queueActive;

  bool get isLocal => kind == 'local';

  /// 是否是**另一台**本机播放端(另一台客户端 / 设备)—— 可被本端遥控的独立播放端。
  /// 语义与主项目前端的 `isRemotePeer` 扩展一致:local 但不是我那条。
  bool get isOtherLocal => isLocal && !self;

  /// 播放端类别标签 —— 与主项目前端 `utils/peerLabel.ts` 同一口径:
  /// **只有「我这条」才叫「本机」**,其余统一显示「客户端」,
  /// 否则在同一账号多端在线时,列表里会出现一排都叫「本机」的行。
  String get kindLabel {
    final loc = l10nNowCurrent();
    if (isLocal) {
      if (self) return loc.peer_self;
      return loc.peer_client;
    }
    return switch (kind) {
      'airplay' => 'AirPlay',
      'group' => loc.peer_group,
      'sendspin' => 'Sendspin',
      _ => 'DLNA',
    };
  }

  /// 队列摘要:`21 首 · 播放中`;空队列返回空串。
  String get queueLabel => queueTotal <= 0
      ? ''
      : queueActive
      ? l10nNowCurrent().peer_queue_total_playing(queueTotal)
      : l10nNowCurrent().peer_queue_total(queueTotal);
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
    this.reportedAtMs,
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
        // 采样时刻(服务端时钟,ms)。**只有客户端实例(local)的 /status 才带** ——
        // 它的 position 是周期上报的采样(实测约 4s 一次),不是实时值;
        // DLNA / AirPlay / Sendspin / 群组的 status 走实时查询,没有这个字段。
        // 注意:不能用 `updatedAt` 代替 —— 对 local 而言那是「队列行写入时刻」,
        // 实测与真实采样时刻能差几十秒(2026-09-16 实测相差 53s)。
        reportedAtMs: (j['reportedAt'] as num?)?.toInt(),
      );

  final String state;
  final double positionSeconds;
  final double durationSeconds;
  final int? volume;
  final bool muted;
  final bool active;

  /// `positionSeconds` 的**采样时刻**(服务端时钟,毫秒)。仅客户端实例有,设备型为 null。
  final int? reportedAtMs;

  bool get playing => state == 'PLAYING';

  PeerStatus copyWith({
    String? state,
    double? positionSeconds,
    double? durationSeconds,
    int? volume,
    bool? muted,
    bool? active,
    int? reportedAtMs,
  }) {
    return PeerStatus(
      state: state ?? this.state,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
      active: active ?? this.active,
      reportedAtMs: reportedAtMs ?? this.reportedAtMs,
    );
  }
}

/// peer 实时队列摘要（GET /v1/peers/:id/queue 的弹窗消费子集）：
/// 当前曲目 + 游标 + 是否在播，用于「流转播放」弹窗第二行与接续按钮可用性。
class PeerNowPlaying {
  const PeerNowPlaying({
    required this.isActive,
    required this.currentIndex,
    required this.total,
    required this.title,
    this.artist,
    this.coverArt,
  });

  final bool isActive;
  final int currentIndex;
  final int total;
  final String title;
  final String? artist;

  /// 当前曲封面标识(服务端 coverArt id,形如 `so-<songId>`)。
  /// 快捷区的圆里就显示它;为空(未在播 / 曲目无封面)时由 UI 落回设备图标。
  final String? coverArt;

  /// 「歌曲 - 歌手」展示串;无曲目返回空串。
  String get trackLabel {
    if (title.isEmpty) return '';
    return artist == null || artist!.isEmpty ? title : '$title - $artist';
  }
}

/// mime → suffix:queueItemToSong 的反向映射,两处必须成对维护。
/// 服务端队列项只存 mime 不存 suffix;反向恢复时必须还原 suffix,否则
/// 播放器无法从链接推断格式(历史教训:Web 端 Howler
/// "No file extension was found" 导致整条恢复队列全灭)。
String mimeToSuffix(String mime) => switch (mime.toLowerCase()) {
      'audio/flac' => 'flac',
      'audio/wav' => 'wav',
      'audio/aac' => 'aac',
      'audio/ogg' => 'ogg',
      'audio/mp4' => 'm4a',
      'audio/opus' => 'opus',
      'audio/ape' => 'ape',
      'audio/x-ms-wma' => 'wma',
      _ => 'mp3',
    };

/// 后端本机队列快照条目 → 可本机播放的 Song(对齐 Web 前端 queueItemToSong)。
/// 与 castQueueItemToSong 的区别:这里要真的播放,必须还原 suffix。
Song queueItemToSong(Map<String, dynamic> it) {
  final albumId = it['albumId'] as String?;
  return Song(
    id: '${it['songId'] ?? ''}',
    title: (it['title'] as String?) ?? l10nNowCurrent().peer_unknown,
    artist: it['artist'] as String?,
    album: it['album'] as String?,
    albumId: albumId,
    duration: (it['duration'] as num?)?.toInt(),
    coverArt: (it['coverArt'] as String?) ??
        (albumId != null ? 'al-$albumId' : null),
    suffix: mimeToSuffix((it['mime'] as String?) ?? ''),
  );
}

/// 队列条目：投递给后端 queue/play 的形状（对齐前端 songToQueueItem）。
Map<String, dynamic> songToQueueItem(dynamic song) => <String, dynamic>{
      'songId': song.id as String?,
      'title': (song.title as String?) ?? l10nNowCurrent().peer_unknown,
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
    title: (it['title'] as String?) ?? l10nNowCurrent().peer_unknown,
    artist: it['artist'] as String?,
    album: it['album'] as String?,
    albumId: albumId,
    duration: (it['duration'] as num?)?.toInt(),
    coverArt: (it['coverArt'] as String?) ?? (albumId != null ? 'al-$albumId' : null),
  );
}
