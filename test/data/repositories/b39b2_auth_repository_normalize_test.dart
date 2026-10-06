// b39b2 —— Route B：auth_repository 剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * auth_repository.dart:318  _normalizeUrl 去掉末尾 '/'
//
// 其余未命中行经源码核查不可达（SubsonicApiClient 各 API 全部内部吞错，
// repository 层的 catch 无异常可捕），逐行结论见文件末尾注释。
//
// 复用 b31a 的「HttpOverrides.global 注入纯内存假 HttpClient」套路：
// AuthRepository 内部自建 Dio 无法注入，且 flutter test 拦截真实 socket
// （所有出站 HTTP 一律 400），只能整体替身 HttpClient。
//
// 产品代码零改动；仅新增 test/。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';

// ---------------------------------------------------------------------------
// 假 HttpClient（与 b31a_auth_repository_cov_test.dart 同款实现，dio 只用到
// 其中少量成员，其余抛 UnimplementedError / 返回默认真值）。
// ---------------------------------------------------------------------------

class _MockHttpState {
  final List<String> calls = <String>[];
}

final _mockHttp = _MockHttpState();

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders([Map<String, Object>? initial]) {
    initial?.forEach(set);
  }

  final Map<String, List<String>> _map = <String, List<String>>{};

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _map.putIfAbsent(name.toLowerCase(), () => <String>[]).add('$value');
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = <String>['$value'];
  }

  @override
  String? value(String name) => _map[name.toLowerCase()]?.join(',');

  @override
  void remove(String name, Object value) {
    _map[name.toLowerCase()]?.remove('$value');
  }

  @override
  void removeAll(String name) => _map.remove(name.toLowerCase());

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _map.forEach(action);

  @override
  void noFolding(String name) {}

  @override
  void clear() => _map.clear();

  @override
  int contentLength = -1;

  @override
  bool chunkedTransferEncoding = false;

  @override
  bool persistentConnection = true;

  String? _host;

  @override
  String? get host => _host;

  @override
  set host(String? value) => _host = value;

  int? _port;

  @override
  int? get port => _port;

  @override
  set port(int? value) => _port = value;

  DateTime? _date;

  @override
  DateTime? get date => _date;

  @override
  set date(DateTime? value) => _date = value;

  DateTime? _expires;

  @override
  DateTime? get expires => _expires;

  @override
  set expires(DateTime? value) => _expires = value;

  DateTime? _ifModifiedSince;

  @override
  DateTime? get ifModifiedSince => _ifModifiedSince;

  @override
  set ifModifiedSince(DateTime? value) => _ifModifiedSince = value;

  ContentType? _contentType;

  @override
  ContentType? get contentType => _contentType;

  @override
  set contentType(ContentType? value) => _contentType = value;
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.method, this.uri);

  @override
  final String method;

  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  final List<Cookie> cookies = <Cookie>[];

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  bool persistentConnection = true;

  @override
  bool bufferOutput = true;

  @override
  int contentLength = -1;

  @override
  Encoding encoding = utf8;

  @override
  HttpConnectionInfo? connectionInfo;

  final Completer<HttpClientResponse> _done = Completer<HttpClientResponse>();

  int responseStatus = 200;

  List<int> responseBody = const <int>[];

  @override
  Future<HttpClientResponse> get done => _done.future;

  @override
  Future<HttpClientResponse> close() async {
    final response = _FakeResponse(responseStatus, responseBody);
    if (!_done.isCompleted) _done.complete(response);
    return response;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    if (!_done.isCompleted) {
      _done.completeError(exception ?? 'aborted', stackTrace);
    }
  }

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) => stream.drain();

  @override
  Future<dynamic> flush() async {}

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = '']) {}
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this.bodyBytes)
      : headers = _FakeHeaders(<String, Object>{
          'content-type': 'application/json; charset=utf-8',
        });

  final List<int> bodyBytes;

  @override
  final int statusCode;

  @override
  final HttpHeaders headers;

  @override
  final String reasonPhrase = 'OK';

  @override
  int get contentLength => bodyBytes.length;

  @override
  bool isRedirect = false;

  @override
  final List<RedirectInfo> redirects = <RedirectInfo>[];

  @override
  final List<Cookie> cookies = <Cookie>[];

  @override
  bool persistentConnection = false;

  @override
  X509Certificate? certificate;

  @override
  HttpConnectionInfo? connectionInfo;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(<List<int>>[bodyBytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future<Socket> detachSocket() => throw UnimplementedError();

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) =>
      throw UnimplementedError();
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.owner);

  final _MockHttpState owner;

  @override
  Duration idleTimeout = const Duration(seconds: 3);

  @override
  Duration? connectionTimeout;

  @override
  int? maxConnectionsPerHost;

  @override
  bool autoUncompress = true;

  @override
  String? userAgent;

  @override
  Future<bool> Function(Uri url, String scheme, String? realm)? authenticate;

  @override
  Future<bool> Function(String host, int port, String scheme, String? realm)?
      authenticateProxy;

  @override
  bool Function(X509Certificate cert, String host, int port)?
      badCertificateCallback;

  @override
  dynamic Function(String line)? keyLog;

  @override
  Future<ConnectionTask<Socket>> Function(Uri url, String? host, int port)?
      connectionFactory;

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) {}

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) {}

  @override
  String Function(Uri url)? findProxy;

  @override
  void close({bool force = false}) {}

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) =>
      openUrl(method, Uri(host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    owner.calls.add('$method $url');
    // 任何请求都回 status=ok 的 subsonic-response（ping / getMusicFolders 通吃）。
    const bodyStr = '{"subsonic-response":{"status":"ok","openSubsonic":true,'
        '"type":"b39b2-sim","serverVersion":"1.0.0"}}';
    return _FakeRequest(method, url)
      ..responseStatus = 200
      ..responseBody = utf8.encode(bodyStr);
  }

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('get', host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('post', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('put', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('patch', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('delete', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('head', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
}

class _FakeHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(_mockHttp);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    HttpOverrides.global = _FakeHttpOverrides();
  });

  tearDownAll(() {
    HttpOverrides.global = null;
  });

  MusicLibrary library() => MusicLibrary(
        id: 'lib-b39b2',
        name: '库',
        username: 'u',
        password: 'p',
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
      );

  test('verifyServerIdentity：新地址带末尾斜杠 → 去尾斜杠后与既有线路同源（line 318）',
      () async {
    const base = 'http://srv.example:4040';
    final existing = library().copyWith(
      addresses: <ServerAddress>[
        ServerAddress(
          id: 'addr-1',
          libraryId: 'lib-b39b2',
          label: 'Primary',
          url: base,
          priority: 0,
          status: ServerAddressStatus.ok,
        ),
      ],
    );
    final newAddress = ServerAddress(
      id: 'addr-2',
      libraryId: 'lib-b39b2',
      label: '重复添加',
      url: '$base/', // 末尾斜杠 → _normalizeUrl 执行 substring 去除（line 318）。
      priority: 1,
    );

    final repo = AuthRepository();
    // ping 成功 → 归一化两侧 URL → 完全一致 → 直接判定同一服务器。
    final same = await repo.verifyServerIdentity(newAddress, existing);
    expect(same, isTrue, reason: '带斜杠的重复地址应归一化为同一服务器');
    expect(_mockHttp.calls.where((c) => c.contains('/rest/ping')), isNotEmpty,
        reason: '前置：ping 已实际发起');
  });

  test('verifyServerIdentity：常规地址（无斜杠）同样能完成同源判定', () async {
    const base = 'http://srv.example:4040';
    final existing = library().copyWith(
      addresses: <ServerAddress>[
        ServerAddress(
          id: 'addr-1',
          libraryId: 'lib-b39b2',
          label: 'Primary',
          url: base,
          priority: 0,
          status: ServerAddressStatus.ok,
        ),
      ],
    );
    final newAddress = ServerAddress(
      id: 'addr-3',
      libraryId: 'lib-b39b2',
      label: '常规',
      url: base,
      priority: 1,
    );

    final repo = AuthRepository();
    final same = await repo.verifyServerIdentity(newAddress, existing);
    expect(same, isTrue);
  });
}

/*
 * 其余未命中行的可达性结论（源码核查，flutter test 环境下均不可达，不虚设用例）：
 *
 * SubsonicApiClient 的每个公开 API（ping/getMusicFolders/getOpenSubsonicExtensions）
 * 都是「try { ... } catch { 记日志 + 返回安全值 }」的全吞错实现；Dio 层抛出的任何
 * 异常都会被 API 层先捕掉。因此 AuthRepository 各方法外层 catch 永远捕不到东西：
 *
 * - 55（detectServerCapabilities 内层 catch）：tempClient.ping() 永不抛 —— ping
 *   自身全捕（DioException 分支 + 泛型分支），只返回 success=false。
 * - 58（detectServerCapabilities 外层 catch）：外层 try 内只有 Dio() 构造、
 *   SubsonicApiClient(dio:) 与 setLibrary（纯赋值），均不抛。
 * - 192-193（_attemptLogin catch）：ping/getOpenSubsonicExtensions/
 *   _computeServerFingerprint 内部全吞错，模型 copyWith 与 Uuid 也不抛。
 * - 285（verifyServerIdentity catch）：同上，链路上所有网络调用都被内层吞掉。
 * - 310-311（_computeServerFingerprint catch）：getMusicFolders 全吞错返回 []。
 */
