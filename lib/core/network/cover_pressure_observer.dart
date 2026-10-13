import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 封面背压信号（服务端在封面**成功响应头**上回传，见 ADR-4）。
///
/// 服务端渲染队列满时不会回 503，而是排队出图后在响应头附：
/// * `X-MusicFlow-Cover-Saturated: 1` —— 命中过饱和；
/// * `Retry-After: 1` —— 建议退避秒数。
/// 客户端只读这两个头，不改变任何请求/响应行为。
@immutable
class CoverPressureSignal {
  const CoverPressureSignal({
    required this.saturated,
    required this.retryAfterSeconds,
  });

  /// 未观测到背压（无头 / 头值非法 / 信号已过期）。
  static const CoverPressureSignal none =
      CoverPressureSignal(saturated: false, retryAfterSeconds: 0);

  final bool saturated;

  /// 建议退避秒数；0 表示服务端未给（或已解析失败）。
  final int retryAfterSeconds;

  @override
  bool operator ==(Object other) {
    return other is CoverPressureSignal &&
        other.saturated == saturated &&
        other.retryAfterSeconds == retryAfterSeconds;
  }

  @override
  int get hashCode => Object.hash(saturated, retryAfterSeconds);

  @override
  String toString() =>
      'CoverPressureSignal(saturated: $saturated, retryAfterSeconds: $retryAfterSeconds)';
}

/// 纯函数：响应头 → 信号。key 大小写不敏感（内部归一）；缺失 / 非正值 →
/// [CoverPressureSignal.none]。
///
/// 抽出为纯函数以便脱离网络环境单测（头解析是背压消费里唯一有分支逻辑的部分）。
CoverPressureSignal parseCoverPressureHeaders(Map<String, String> headers) {
  // 归一 key：服务端头名可能任意大小写，本函数自负归一（调用方传原始大小写即可）。
  final normalized = <String, String>{};
  headers.forEach((name, value) {
    normalized[name.toLowerCase()] = value;
  });
  final saturatedRaw = normalized['x-musicflow-cover-saturated']?.trim();
  final retryRaw = normalized['retry-after']?.trim();

  // 饱和标记用**白名单**：仅 '1' / 'true'（大小写不敏感）视为饱和；其余
  // （'0' / 缺失 / 空串 / 未来可能出现的其它字面量）一律未饱和。原实现
  // 「非 '0' 且非空即饱和」会把 'false' / 'no' 之类误判成饱和。
  final saturated = saturatedRaw == '1' ||
      (saturatedRaw != null && saturatedRaw.toLowerCase() == 'true');

  // Retry-After 按 delta-seconds 解析（服务端只发秒数，不发 HTTP-date）。
  var retryAfter = 0;
  if (retryRaw != null && retryRaw.isNotEmpty) {
    final parsed = int.tryParse(retryRaw);
    if (parsed != null && parsed > 0) retryAfter = parsed;
  }

  if (!saturated && retryAfter <= 0) return CoverPressureSignal.none;
  return CoverPressureSignal(saturated: saturated, retryAfterSeconds: retryAfter);
}

/// 是否封面 URL（服务端 `/rest/getCoverArt`，query 带 id/size/鉴权参数）。
///
/// 只按 path 判定（大小写不敏感）：鉴权参数每次可能不同，不可作为匹配依据。
bool isCoverArtUrl(Uri uri) {
  return uri.path.toLowerCase().endsWith('/getcoverart');
}

/// 封面背压观测器：经 `HttpOverrides.global` 透明包装 `HttpClient`，
/// **只 tap** 封面 URL 的响应头，其余流量零行为改变。
///
/// 安装时机：必须在 `runApp` 之前 —— Flutter 的 `NetworkImage` 内部共享
/// client 是 `static final HttpClient()`（懒初始化，首次图片请求时才创建），
/// 装的晚了共享 client 已用真实工厂建成，拦截不到。
///
/// 兼容性：`debugNetworkImageHttpClientProvider`（测试注入）仅在 debug 模式
/// 且优先于共享 client，故既有封面测试的注入缝不受本观测器影响。
class CoverPressureObserver {
  CoverPressureObserver._();

  /// 信号有效期兜底：服务端未给 `Retry-After`（或非法）时的默认退避窗；
  /// 有合法 `Retry-After` 时以它为准（服务端建议多久就等多久，不过度压制）。
  static const Duration signalTtl = Duration(seconds: 30);

  static CoverPressureSignal _signal = CoverPressureSignal.none;
  static DateTime? _signalAt;

  /// 当前这枚信号的生效时长：`Retry-After` 合法（>0）时按其秒数，否则 [signalTtl]。
  static Duration _hold = signalTtl;

  /// 安装全局拦截（幂等；重复安装只是重复包装，无副作用但没必要）。
  ///
  /// **保留既有全局覆盖**：安装前先捕获 [HttpOverrides.current] 作为内层工厂
  /// 委派下去（与 dart:io `_HttpOverridesScope` 同一姿势）。否则直接赋值会把
  /// 别处已装的覆盖（代理/测试桩）无声顶掉。
  static void install() {
    HttpOverrides.global = _CoverPressureHttpOverrides(HttpOverrides.current);
  }

  /// 记录一组响应头（小写/大写均可，内部归一）。
  static void recordHeaders(Map<String, String> headers) {
    final signal = parseCoverPressureHeaders(headers);
    if (signal == CoverPressureSignal.none) return;
    _signal = signal;
    _signalAt = DateTime.now();
    // 生效时长按服务端建议：Retry-After 秒数优先，缺失/非法才回落兜底 TTL。
    _hold = signal.retryAfterSeconds > 0
        ? Duration(seconds: signal.retryAfterSeconds)
        : signalTtl;
  }

  /// 当前有效信号（过期返回 none）。
  static CoverPressureSignal currentSignal({DateTime? now}) {
    final at = _signalAt;
    if (at == null) return CoverPressureSignal.none;
    final now0 = now ?? DateTime.now();
    if (now0.difference(at) > _hold) return CoverPressureSignal.none;
    return _signal;
  }

  /// 当前是否处于服务端饱和窗口。
  static bool get isSaturated => currentSignal().saturated;

  /// 当前信号剩余毫秒数（无信号返回 0）。
  static int signalRemainingMs({DateTime? now}) {
    final at = _signalAt;
    if (at == null) return 0;
    final now0 = now ?? DateTime.now();
    final remaining = _hold.inMilliseconds - now0.difference(at).inMilliseconds;
    return remaining > 0 ? remaining : 0;
  }

  /// 测试/调试：清空信号态。
  static void resetForTest() {
    _signal = CoverPressureSignal.none;
    _signalAt = null;
    _hold = signalTtl;
  }
}

/// 全局 `HttpOverrides`：把每个 `HttpClient()` 换成只 tap 封面头的透明包装。
class _CoverPressureHttpOverrides extends HttpOverrides {
  _CoverPressureHttpOverrides(this._base);

  /// 安装前已生效的全局覆盖（可能为 null）；有则委派，无则走父类真实工厂。
  final HttpOverrides? _base;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner =
        _base?.createHttpClient(context) ?? super.createHttpClient(context);
    return _CoverPressureHttpClient(inner);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    return _base?.findProxyFromEnvironment(url, environment) ??
        super.findProxyFromEnvironment(url, environment);
  }
}

/// 透明包装的 `HttpClient`：全接口编译期委派，仅包装请求以观测封面响应头。
class _CoverPressureHttpClient implements HttpClient {
  _CoverPressureHttpClient(this._delegate);

  final HttpClient _delegate;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return _CoverPressureHttpRequest(await _delegate.openUrl(method, url));
  }

  @override
  Future<HttpClientRequest> open(
      String method, String host, int port, String path) async {
    return _CoverPressureHttpRequest(
        await _delegate.open(method, host, port, path));
  }

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _wrap(_delegate.get(host, port, path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _wrap(_delegate.getUrl(url));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _wrap(_delegate.head(host, port, path));

  @override
  Future<HttpClientRequest> headUrl(Uri url) => _wrap(_delegate.headUrl(url));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _wrap(_delegate.post(host, port, path));

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _wrap(_delegate.postUrl(url));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _wrap(_delegate.put(host, port, path));

  @override
  Future<HttpClientRequest> putUrl(Uri url) => _wrap(_delegate.putUrl(url));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _wrap(_delegate.delete(host, port, path));

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _wrap(_delegate.deleteUrl(url));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _wrap(_delegate.patch(host, port, path));

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _wrap(_delegate.patchUrl(url));

  Future<HttpClientRequest> _wrap(Future<HttpClientRequest> inner) async {
    return _CoverPressureHttpRequest(await inner);
  }

  @override
  set idleTimeout(Duration value) => _delegate.idleTimeout = value;

  @override
  Duration get idleTimeout => _delegate.idleTimeout;

  @override
  set connectionTimeout(Duration? value) => _delegate.connectionTimeout = value;

  @override
  Duration? get connectionTimeout => _delegate.connectionTimeout;

  @override
  set userAgent(String? value) => _delegate.userAgent = value;

  @override
  String? get userAgent => _delegate.userAgent;

  @override
  set maxConnectionsPerHost(int? value) =>
      _delegate.maxConnectionsPerHost = value;

  @override
  int? get maxConnectionsPerHost => _delegate.maxConnectionsPerHost;

  @override
  set autoUncompress(bool value) => _delegate.autoUncompress = value;

  @override
  bool get autoUncompress => _delegate.autoUncompress;

  @override
  void addCredentials(
      Uri url, String realm, HttpClientCredentials credentials) {
    _delegate.addCredentials(url, realm, credentials);
  }

  @override
  void addProxyCredentials(
      String host, int port, String realm, HttpClientCredentials credentials) {
    _delegate.addProxyCredentials(host, port, realm, credentials);
  }

  @override
  void close({bool force = false}) {
    _delegate.close(force: force);
  }

  // 以下为本版 dart:io HttpClient 的 set-only 成员（接口有 setter、无 getter），
  // 全部透传委派。
  @override
  set authenticate(Future<bool> Function(Uri url, String scheme, String? realm)? f) {
    _delegate.authenticate = f;
  }

  @override
  set authenticateProxy(
      Future<bool> Function(String host, int port, String scheme, String? realm)? f) {
    _delegate.authenticateProxy = f;
  }

  @override
  set badCertificateCallback(
      bool Function(X509Certificate cert, String host, int port)? callback) {
    _delegate.badCertificateCallback = callback;
  }

  @override
  set connectionFactory(
      Future<ConnectionTask<Socket>> Function(Uri url, String? proxyHost, int? proxyPort)?
          factory) {
    _delegate.connectionFactory = factory;
  }

  @override
  set keyLog(void Function(String line)? value) {
    _delegate.keyLog = value;
  }

  @override
  set findProxy(String Function(Uri url)? f) {
    _delegate.findProxy = f;
  }
}

/// 透明包装的 `HttpClientRequest`：全接口编译期委派。
///
/// 唯一的观测点：[close] —— 本版 `dart:io` 的 `HttpClientRequest` 无
/// `response` getter，响应统一由 `close()` 返回。在 `close()` 返回前同步
/// 读取封面 URL 的响应头，随后原样返回原响应对象（不包装响应体，
/// 零行为改变）。
class _CoverPressureHttpRequest implements HttpClientRequest {
  _CoverPressureHttpRequest(this._delegate);

  final HttpClientRequest _delegate;

  @override
  Future<HttpClientResponse> close() async {
    final response = await _delegate.close();
    if (isCoverArtUrl(_delegate.uri)) {
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        // 同名多值头（如多个 Retry-After）取拼接值；解析侧只认首个正整数，
        // 拼接形式 '1, 2' 会被 int.tryParse 拒绝 → none，行为安全。
        headers[name.toLowerCase()] = values.join(',');
      });
      CoverPressureObserver.recordHeaders(headers);
    }
    return response;
  }

  @override
  set encoding(Encoding value) => _delegate.encoding = value;

  @override
  Encoding get encoding => _delegate.encoding;

  @override
  void add(List<int> data) => _delegate.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _delegate.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      _delegate.addStream(stream);

  @override
  Future<HttpClientResponse> get done => _delegate.done;

  @override
  Future<void> flush() => _delegate.flush();

  @override
  void write(Object? object) => _delegate.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _delegate.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _delegate.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _delegate.writeln(object);

  @override
  HttpHeaders get headers => _delegate.headers;

  @override
  bool get persistentConnection => _delegate.persistentConnection;

  @override
  set persistentConnection(bool value) =>
      _delegate.persistentConnection = value;

  @override
  bool get followRedirects => _delegate.followRedirects;

  @override
  set followRedirects(bool value) => _delegate.followRedirects = value;

  @override
  int get maxRedirects => _delegate.maxRedirects;

  @override
  set maxRedirects(int value) => _delegate.maxRedirects = value;

  @override
  String get method => _delegate.method;

  @override
  Uri get uri => _delegate.uri;

  @override
  int get contentLength => _delegate.contentLength;

  @override
  set contentLength(int value) => _delegate.contentLength = value;

  @override
  bool get bufferOutput => _delegate.bufferOutput;

  @override
  set bufferOutput(bool value) => _delegate.bufferOutput = value;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _delegate.abort(exception, stackTrace);

  @override
  HttpConnectionInfo? get connectionInfo => _delegate.connectionInfo;

  @override
  List<Cookie> get cookies => _delegate.cookies;
}
