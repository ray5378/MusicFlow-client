/// Describes how a logical song position maps onto a stream that was started
/// with Subsonic's `timeOffset` parameter.
class TranscodedStreamSeekTarget {
  final Duration logicalPosition;
  final Duration serverOffset;
  final Duration sourcePosition;

  const TranscodedStreamSeekTarget._({
    required this.logicalPosition,
    required this.serverOffset,
    required this.sourcePosition,
  });

  factory TranscodedStreamSeekTarget.fromLogical(Duration position) {
    final logicalPosition = position < Duration.zero ? Duration.zero : position;
    final serverOffset = Duration(seconds: logicalPosition.inSeconds);
    return TranscodedStreamSeekTarget._(
      logicalPosition: logicalPosition,
      serverOffset: serverOffset,
      sourcePosition: logicalPosition - serverOffset,
    );
  }

  Duration toLogical(Duration sourcePosition, {Duration? maximum}) {
    return addPlaybackPositionOffset(
      sourcePosition,
      serverOffset,
      maximum: maximum,
    );
  }
}

/// Whether the requested Subsonic stream is expected to be transcoded.
///
/// Navidrome transcodes when the requested format differs from the source, or
/// when the requested maximum bitrate is below the source bitrate. Requesting
/// the source's existing format with a high enough bitrate can still return the
/// original byte-seekable file. Live transcoding responses are not byte-
/// seekable until the server-side cache is complete, so only those streams
/// should be seeked by rebuilding the URL with `timeOffset`.
///
/// P2-3 (MusicFlow 音频流水线):`serverPipelinedHttp=true` 时无条件返回 true ——
/// 服务端 P2-1 起 `/rest/stream` 全通道走实时管道(D9,无直传旁路),即使请求格式
/// 与源格式一致、码率不限,返回的也是不可字节 seek 的实时流,拖动进度必须走
/// timeOffset 重拉。调用方按服务端能力判定后传入(见 [serverPipesAllHttpStreams])。
bool shouldUseServerTimeOffsetSeek({
  required String? requestedFormat,
  required int? requestedMaxBitRate,
  required String? sourceFormat,
  required int? sourceBitRate,
  bool serverPipelinedHttp = false,
}) {
  // 服务端全管道化:一切 HTTP 流都是实时流,旧「格式一致可字节 seek」结论作废。
  if (serverPipelinedHttp) return true;
  final format = _normalizeFormat(requestedFormat);
  if (format != null && format.isNotEmpty && format != 'raw') {
    final originalFormat = _normalizeFormat(sourceFormat);
    final maxBitRate = _normalizeBitRateKbps(requestedMaxBitRate);
    final originalBitRate = _normalizeBitRateKbps(sourceBitRate);
    final canUseOriginalStream =
        originalFormat == format &&
        (maxBitRate == 0 ||
            (originalBitRate > 0 && maxBitRate >= originalBitRate));
    if (canUseOriginalStream) return false;
    return true;
  }

  final maxBitRate = _normalizeBitRateKbps(requestedMaxBitRate);
  final originalBitRate = _normalizeBitRateKbps(sourceBitRate);
  return maxBitRate > 0 && originalBitRate > maxBitRate;
}

Duration addPlaybackPositionOffset(
  Duration sourcePosition,
  Duration offset, {
  Duration? maximum,
}) {
  var logical = sourcePosition + offset;
  if (logical < Duration.zero) logical = Duration.zero;
  if (maximum != null && maximum > Duration.zero && logical > maximum) {
    logical = maximum;
  }
  return logical;
}

int _normalizeBitRateKbps(int? bitRate) {
  if (bitRate == null || bitRate <= 0) return 0;
  return bitRate >= 10000 ? bitRate ~/ 1000 : bitRate;
}

/// 服务端全管道化的最低版本(P2-3):`/rest/stream` 在此版本起无直传旁路,
/// 全部返回实时流(带 `X-MusicFlow-Transcoded: 1` 响应头)。
/// 取值依据:管道化(P2-1)合入 main 时后端 package.json 为 3.0.46,
/// 故首个含管道的发版号 ≥ 3.0.47。若发版跳号(如直接 3.1.0),semver 比较
/// 依然成立;只有「发版号回退」会误判,发版时顺手核对本常量即可。
const String kPipelineMinServerVersion = '3.0.47';

/// 服务端能力判定(P2-3):当前连接的服务端是否全通道管道化。
/// - 非 MusicFlow 服务端(Navidrome 等):false,沿用旧格式/码率判定;
/// - MusicFlow 老版本(< 3.0.47):false,直传仍在,字节 seek 有效;
/// - 版本未知/解析失败:false(保守,保持旧行为,不劣化);
/// - MusicFlow ≥ 3.0.47:true,一切流走 timeOffset 重拉。
bool serverPipesAllHttpStreams({
  required String? serverType,
  required String? serverVersion,
}) {
  if (serverType?.trim().toLowerCase() != 'musicflow') return false;
  return _versionGte(serverVersion, kPipelineMinServerVersion);
}

/// 容错 semver 比较:取前导 `x.y.z` 数字段,缺段按 0,后缀(-rc1/+build)忽略;
/// 解析失败返回 false(未知 → 保守按老服务端处理)。
bool _versionGte(String? version, String min) {
  List<int> parse(String v) {
    final m = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(v.trim());
    if (m == null) return const [];
    return [m[1]!, m[2], m[3]].map((s) => s == null ? 0 : int.parse(s)).toList();
  }
  final v = parse(version ?? '');
  final threshold = parse(min);
  if (v.isEmpty || threshold.isEmpty) return false;
  for (var i = 0; i < 3; i++) {
    if (v[i] != threshold[i]) return v[i] > threshold[i];
  }
  return true;
}

String? _normalizeFormat(String? format) {
  final normalized = format?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  return normalized.startsWith('.') ? normalized.substring(1) : normalized;
}
