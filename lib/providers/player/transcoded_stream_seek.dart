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

/// 服务端能力判定:当前连接的服务端是否全通道管道化。
/// - 非 MusicFlow 服务端(Navidrome 等):false,沿用旧格式/码率判定;
/// - MusicFlow(type 自报名带后缀、版本未知、版本快照落后都算):true,一切流
///   走 timeOffset 重拉。
///
/// ★★ 2026-09-23 真机事故:此处**退役了版本门控**(原门槛 `3.0.47`,即管道化
/// P2-1 上线版本)。原因:判定所依据的 [serverVersion] 是**登录时写一次**的
/// 静态快照(客户端只存 DB、此后从不刷新)。服务端升级到管道化版本之后,老库
/// 里记的仍是登录当年的旧号 → `_versionGte` 恒 false → 管道化被判死 →
/// `_seekByReloadStream` 永远为假 → 「拖/点进度条一律从头播放」在 Android 上
/// 永久复现。现场证据:服务端 `/rest/ping` 实报
/// `serverVersion=4.0.14 / type=MusicFlow`,手机端 `[SEEKDBG]` 却是
/// `reload=false origin=- flag=false`(裸 seek);Windows 因 libmpv 自身能处理
/// HTTP 流的 seek 而不显形,只有 Android(ExoPlayer)暴露。
///
/// 误判代价极不对称,故一律按管道化处理:
/// - 把真·管道化服务端判成「非管道化」= 拖动彻底失效(本次事故);
/// - 把老服务端(直传可字节 seek)判成「管道化」= 多一次带 `timeOffset` 的重拉,
///   而 `timeOffset` 是标准 Subsonic/OpenSubsonic 参数,老服务端同样接受。
bool serverPipesAllHttpStreams({
  required String? serverType,
  // 入参保留:仍参与调用方日志与排查,但**不再作为门控**(见上)。
  required String? serverVersion,
}) {
  final type = serverType?.trim().toLowerCase();
  // 只认前缀:'MusicFlow'/'musicflow'/'musicflow-web' 这类自报名都算本服务端;
  // 严格等值会在服务端把 type 写成带后缀的形状时把管道化判定判死(→ 拖动退化
  // 成源内 seek → 从头播),所以这里放宽到前缀。
  if (type == null || !type.startsWith(kMusicFlowServerTypePrefix)) {
    return false;
  }
  return true;
}

/// MusicFlow 服务端 type 的识别前缀(见 [serverPipesAllHttpStreams])。
const String kMusicFlowServerTypePrefix = 'musicflow';

String? _normalizeFormat(String? format) {
  final normalized = format?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  return normalized.startsWith('.') ? normalized.substring(1) : normalized;
}

// ==================== 本机 seek 的重拉路由(2026-09-23 真机事故) ====================
//
// 现场:Android 本机播放任意源的歌,拖进度条/点击进度条后**声音始终从头开始**,
// UI 进度却停在拖动的位置。240 侧日志证明服务端完全正常(同一首 timeOffset=183
// 的流刚好短 183s、从未收到无偏移的重拉请求);客户端日志则显示 seek 走的是裸
// `player.seek()`(`seek execute`),而"漂移 > 2s 才升级重拉"的兜底**永远不触发**
// ——just_audio 在 seek 之后会**立刻**把 position 报成目标值(driftMs 稳定在
// 200~230ms),哪怕底层是实时管道流、解码器其实从第 0 字节重来。也就是说
// position 在这个场景里会撒谎,不能作为"seek 成功"的证据。
//
// 而走哪条分支原先只看一个可变字段 `_seekByReloadStream`(由服务端能力判定写入)。
// 这个字段会在若干路径上被清成 false(起流的 `_clearStreamContext()` 之后加载被
// 作废而提前 return、preview 起流显式写 false 等),一旦它错了,seek 就静默退化
// 成"重复一遍无效动作",且没有任何信号能纠正 —— 于是拖动 = 从头播。
//
// 根治:不再依赖那个字段的**可信度**,改用"当前真实加载的音源地址是不是本服务端
// 的流"来判定。播放器自己加载的 URL 是事实,不是记账。

/// 本机 seek 的重拉路由判定结果。
class SeekReloadPlan {
  /// 重建后的流地址(已带上 `timeOffset`)。
  final String url;

  /// 判定来源,仅用于日志与测试断言:
  /// - `context`      流上下文完整且标记可重拉(既有路径)
  /// - `context_lost` 上下文丢失,改用播放器当前真实加载的地址(事故主因)
  /// - `context_plain` 上下文在但标记不可重拉,而地址仍是本服务端流(preview)
  final String origin;

  /// 基准地址里声明的转码格式 / 码率(用于同步流上下文,`-` 视为未指定)。
  final String? format;
  final int? maxBitRate;

  const SeekReloadPlan({
    required this.url,
    required this.origin,
    this.format,
    this.maxBitRate,
  });
}

/// 该地址是否是**本服务端**的流地址:http(s) + 路径落在 `/rest/stream`
/// (或 `/rest/stream-remote`) + 带「这是本服务端流」的参数痕迹。
///
/// 外部源直链(在线源的 CDN 地址)与本地文件(离线缓存 `file://`)都不满足 —— 它们
/// 既不在 `/rest/stream` 路径下,也无法通过改写 URL 让服务端从指定位置重新出流。
///
/// ★ 2026-09-23 真机事故:原先硬性要求 Subsonic 签名三件套(`u`/`t`/`s`),只覆盖
/// 「用户名+密码登录」一条鉴权路径。客户端还有另外两种形态会让该判据恒 false:
/// - **API Key 鉴权**:参数是 `apiKey`/`v`/`c`/`f`,**没有** `u`/`t`/`s`;
/// - 密码登录但库记录里 `password` 缺失(老库/复用旧会话):只带 `v`/`c`/`f`。
/// 判据一 false,重拉分支被整个跳过 → 又回到「拖到哪都从头播」。
/// 现改为认「歌曲标识 **或** 任一鉴权痕迹」,两种鉴权都能命中。
bool isServerStreamUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final path = uri.path;
  if (!path.endsWith('/rest/stream') && !path.endsWith('/rest/stream-remote')) {
    return false;
  }
  final q = uri.queryParameters;
  // 歌曲标识:`/rest/stream` 必带 `id`,`/rest/stream-remote` 必带 `provider`。
  final hasIdentity = q.containsKey('id') || q.containsKey('provider');
  // 鉴权痕迹:token(`u`/`t`/`s`)或 API Key(`apiKey`)任一即可。
  final hasAuth = q.containsKey('u') ||
      q.containsKey('t') ||
      q.containsKey('s') ||
      q.containsKey('apiKey');
  return hasIdentity || hasAuth;
}

/// 在 [baseUrl] 上改写 `timeOffset`:[offset] 为 0 时**移除**该参数(等价"从头"),
/// 其余查询参数(含签名与 format/maxBitRate)原样保留。
String buildTimeOffsetStreamUrl(String baseUrl, Duration offset) {
  final uri = Uri.parse(baseUrl);
  final params = Map<String, String>.from(uri.queryParameters);
  final seconds = offset.inSeconds;
  if (seconds > 0) {
    params['timeOffset'] = '$seconds';
  } else {
    params.remove('timeOffset');
  }
  return uri.replace(queryParameters: params).toString();
}

String? _stringParam(String url, String key) {
  final value = Uri.tryParse(url)?.queryParameters[key]?.trim();
  if (value == null || value.isEmpty || value == '-') return null;
  return value;
}

int? _intParam(String url, String key) {
  final value = _stringParam(url, key);
  if (value == null) return null;
  final parsed = int.tryParse(value);
  return (parsed == null || parsed <= 0) ? null : parsed;
}

/// 决定本机 seek 走「重拉服务端流」还是「源内 seek」;返回 null 表示源内 seek。
///
/// 判定优先级(越靠前越可信):
///  1. `context`       流上下文完整且标记可重拉 —— 既有路径,保持不劣化;
///  2. `context_lost`  上下文丢失(或不可信),但播放器**当前真实加载**的地址就是
///                     本服务端流 —— 事故兜底:无论如何都能重建出正确的重拉地址;
///  3. `context_plain` 上下文在但标记不可重拉(preview 起流一直写 false),而地址
///                     仍是本服务端流(`/rest/stream-remote` 同样支持 timeOffset)
///                     —— 顺手把试听链路的拖动一起修掉。
///
/// [serverPipelinedHttp] 为 false(明确识别出非 MusicFlow、且版本已知的老服务端/
/// 其它实现)时**一律返回 null**:那些服务端的直传流本身可字节 seek,重拉反而会把
/// 行为改坏;它们的拖动仍由源内 seek + 漂移兜底负责。
SeekReloadPlan? resolveSeekReloadPlan({
  required String songId,
  required Duration target,
  required String? contextSongId,
  required String? contextUrl,
  required bool contextAllowsReload,
  required String? loadedSourceUrl,
  required bool serverPipelinedHttp,
}) {
  if (!serverPipelinedHttp) return null;

  final contextMatchesSong = contextSongId == songId;
  final offset = Duration(seconds: target.inSeconds < 0 ? 0 : target.inSeconds);

  String? base;
  var origin = '';
  if (contextAllowsReload &&
      contextMatchesSong &&
      isServerStreamUrl(contextUrl)) {
    base = contextUrl;
    origin = 'context';
  } else if ((contextSongId == null || contextMatchesSong) &&
      isServerStreamUrl(loadedSourceUrl)) {
    base = loadedSourceUrl;
    origin = 'context_lost';
  } else if (contextMatchesSong && isServerStreamUrl(contextUrl)) {
    base = contextUrl;
    origin = 'context_plain';
  }
  if (base == null) return null;

  return SeekReloadPlan(
    url: buildTimeOffsetStreamUrl(base, offset),
    origin: origin,
    format: _stringParam(base, 'format'),
    maxBitRate: _intParam(base, 'maxBitRate'),
  );
}
