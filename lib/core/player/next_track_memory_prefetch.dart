// ==================== 下一首内存预取（在线播放 / 关闭离线缓存时） ====================
//
// 背景：客户端在线播放走 just_audio 直接吃 `/rest/stream`。切歌发生在当前曲
// `completed` 之后，那一刻才建下一个源 → 外网无损（单曲 30~80MB）要等
// 「首包 + 整轨下载」才出声。
//
// 离线缓存开启时由 offline_cache_daemon 落盘预取（另一条链路）；本文件覆盖
// **不开离线缓存**的场景：把下一首整轨拉进内存（有上限、可取消），切歌时用
// [MemoryAudioSource] 直接喂给播放器 → 0 网络等待，且不写磁盘、不碰离线缓存。
//
// 纪律：
//   - 同一时间只保留 1 首；超上限（默认 64MB）整首丢弃，静默回退在线流。
//   - 失败/取消/超限一律静默：预取只是加速，绝不改变「能不能播」。
//   - 音质签名（format@maxBitRate）不一致时不用（避免把 320k 当无损播）。
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:just_audio/just_audio.dart';

/// 已就绪的内存预取结果。
class MemoryPrefetchedTrack {
  const MemoryPrefetchedTrack({
    required this.songId,
    required this.qualityKey,
    required this.bytes,
  });

  final String songId;
  final String qualityKey;
  final Uint8List bytes;
}

/// 单曲内存预取器：拉整轨字节 + 消费/释放。
class NextTrackMemoryPrefetch {
  NextTrackMemoryPrefetch({this.maxBytes = 64 * 1024 * 1024});

  /// 单曲上限（字节）。无损单曲通常 20~60MB；超过就放弃本次预取。
  final int maxBytes;

  MemoryPrefetchedTrack? _ready;
  String? _inflightSongId;
  CancelToken? _cancelToken;
  int _generation = 0;

  /// 已备好的歌曲 id（无则 null）。
  String? get readySongId => _ready?.songId;

  /// 是否有进行中的下载。
  bool get isDownloading => _inflightSongId != null;

  /// 开始预取；同一首重复调用幂等。已备好的其它歌会被释放。
  Future<void> start({
    required Dio dio,
    required String songId,
    required String qualityKey,
    required String url,
    int? expectedBytes,
  }) async {
    if (songId.isEmpty || url.isEmpty) return;
    if (_ready?.songId == songId && _ready?.qualityKey == qualityKey) return;
    if (_inflightSongId == songId) return;
    // 明显超上限的直接不做（服务端管道无 Content-Length，只能靠库里 size 兜底）。
    if (expectedBytes != null && expectedBytes > maxBytes) return;

    final generation = ++_generation;
    _cancelToken?.cancel('replaced');
    final token = CancelToken();
    _cancelToken = token;
    _inflightSongId = songId;
    if (_ready != null && _ready!.songId != songId) _ready = null;

    try {
      final res = await dio.get<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream),
        cancelToken: token,
      );
      final stream = res.data?.stream;
      if (stream == null) return;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        if (generation != _generation || token.isCancelled) return;
        builder.add(chunk);
        if (builder.length > maxBytes) return; // 超上限：整首丢弃
      }
      if (generation != _generation || token.isCancelled) return;
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) return;
      _ready = MemoryPrefetchedTrack(
        songId: songId,
        qualityKey: qualityKey,
        bytes: bytes,
      );
    } catch (_) {
      // 网络错误/取消：静默，切歌时回退在线流。
    } finally {
      if (generation == _generation) {
        _inflightSongId = null;
        _cancelToken = null;
      }
    }
  }

  /// 取走已备好的字节（取走即消费；音质签名不一致返回 null 并保留？否 —— 直接丢弃）。
  Uint8List? take(String songId, String qualityKey) {
    final ready = _ready;
    if (ready == null) return null;
    _ready = null;
    if (ready.songId != songId || ready.qualityKey != qualityKey) return null;
    return ready.bytes;
  }

  /// 中止进行中的下载并释放已备字节（切流转/清队列/登出时调用）。
  void reset() {
    _generation++;
    _cancelToken?.cancel('reset');
    _cancelToken = null;
    _inflightSongId = null;
    _ready = null;
  }
}

/// 把内存字节作为 just_audio 音源（支持 Range 请求 → 本地 seek 不需要重拉）。
class MemoryAudioSource extends StreamAudioSource {
  MemoryAudioSource(this.bytes, {this.contentType, super.tag});

  final Uint8List bytes;
  final String? contentType;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = (start ?? 0).clamp(0, bytes.length);
    final to = (end ?? bytes.length).clamp(from, bytes.length);
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream<List<int>>.value(bytes.sublist(from, to)),
      contentType: contentType ?? 'application/octet-stream',
    );
  }

  /// 按「实际请求的格式」给 MIME（iOS/Android 解码器需要，猜错会拒绝播放）。
  static MemoryAudioSource of(Uint8List bytes, {String? transcodeFormat, String? suffix}) {
    return MemoryAudioSource(bytes, contentType: mimeType(transcodeFormat, suffix));
  }

  static String? mimeType(String? transcodeFormat, String? suffix) {
    final f = (transcodeFormat ?? suffix ?? '').toLowerCase();
    switch (f) {
      case 'flac':
        return 'audio/flac';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
      case 'aac':
      case 'mp4':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'ape':
      case 'wv':
      case 'tta':
      case 'dff':
      case 'dsf':
      case 'tak':
        return 'application/octet-stream';
      default:
        return null;
    }
  }
}
