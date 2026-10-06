// AuthRepository 覆盖率补测 —— batch31 (A 路 worker)。
//
// 产品代码零改动。AuthRepository 内部自己 new Dio + SubsonicApiClient，无法注入，
// 故用 HttpOverrides.global 注入纯内存假 HttpClient（不碰真 socket，见踩坑 #74-B）。
// 假响应按 URL path 路由：/rest/ping、/rest/getMusicFolders、
// /rest/getOpenSubsonicExtensions 各自返回对应 subsonic-response。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';

// ---------------------------------------------------------------------------
// 假 HttpClient（给 Dio 用，dart:io 的 HttpClient/Request/Response/Headers 均
// 只有 factory 构造，只能 implements 逐个成员手写；dio 只用到的成员返回默认真值，
// 其余抛 UnimplementedError）。
// ---------------------------------------------------------------------------

class _MockHttpState {
  int statusCode = 200;
  String body = '{}';
  Object? failWith;
  final List<String> calls = <String>[];

  /// 非空时 openUrl 按 (method, url) 返回 (statusCode, body)。优先级高于下面两个。
  (int, String) Function(String method, Uri url)? responder;

  void reset() {
    statusCode = 200;
    body = '{}';
    failWith = null;
    calls.clear();
    responder = null;
  }
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
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  HttpConnectionInfo? connectionInfo;

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
  String Function(Uri url) get findProxy => (Uri url) => 'DIRECT';

  @override
  set findProxy(String Function(Uri url)? f) {}

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
    final failure = owner.failWith;
    if (failure != null) throw failure;
    int status = owner.statusCode;
    String bodyStr = owner.body;
    if (owner.responder != null) {
      final r = owner.responder!(method, url);
      status = r.$1;
      bodyStr = r.$2;
    }
    return _FakeRequest(method, url)
      ..responseStatus = status
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

// ---------------------------------------------------------------------------
// 响应体构造
// ---------------------------------------------------------------------------

String _okBody({
  bool openSubsonic = true,
  String type = 'Navidrome',
  String version = '0.50.0',
  List<Map<String, String>> folders = const [
    {'id': '1', 'name': 'Music'},
    {'id': '2', 'name': 'Movies'},
  ],
  bool withExtensions = true,
}) {
  final folderJson = folders
      .map((f) => '{"id":"${f['id']}","name":"${f['name']}"}')
      .join(',');
  final extJson = withExtensions
      ? ',"openSubsonicExtensions":[{"name":"bookmarks"},{"name":"podcast"}]'
      : '';
  return '''
{
  "subsonic-response": {
    "status": "ok",
    "openSubsonic": $openSubsonic,
    "type": "$type",
    "serverVersion": "$version",
    "musicFolders": {"musicFolder": [$folderJson]}
    $extJson
  }
}''';
}

/// 按 path 路由的默认 responder 装配。
void _setResponder({
  bool pingOk = true,
  List<Map<String, String>> folders = const [
    {'id': '1', 'name': 'Music'},
    {'id': '2', 'name': 'Movies'},
  ],
  bool foldersFail = false,
  Map<String, List<Map<String, String>>>? foldersByHost,
  bool extensionsFail = false,
  Set<String>? pingFailHosts,
}) {
  _mockHttp.responder = (method, url) {
    final p = url.path;
    if (p.endsWith('/getOpenSubsonicExtensions')) {
      if (extensionsFail) return (500, '');
      return (200, _okBody(folders: folders));
    }
    if (p.endsWith('/ping')) {
      if (!pingOk || (pingFailHosts != null && pingFailHosts.contains(url.host))) {
        return (500, '{"subsonic-response":{"status":"failed"}}');
      }
      return (200, _okBody(folders: folders));
    }
    if (p.endsWith('/getMusicFolders')) {
      if (foldersFail) return (500, '');
      final hostFolders = foldersByHost?[url.host];
      return (200, _okBody(folders: hostFolders ?? folders));
    }
    return (200, _okBody(folders: folders));
  };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

MusicLibrary _lib({
  MusicLibraryAuthType authType = MusicLibraryAuthType.token,
  String? username,
  String? password,
  String? apiKey,
  List<ServerAddress>? addresses,
  Map<String, dynamic>? extensions,
}) {
  return MusicLibrary(
    id: 'lib-1',
    name: 'TestLib',
    authType: authType,
    username: username,
    password: password,
    apiKey: apiKey,
    createdAt: DateTime(2024),
    updatedAt: DateTime(2024),
    addresses: addresses ?? const [],
    extensions: extensions ?? const {},
  );
}

ServerAddress _addr(String url, {int priority = 0, String id = 'a1'}) {
  return ServerAddress(
    id: id,
    libraryId: 'lib-1',
    label: url,
    url: url,
    priority: priority,
  );
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
  });

  setUp(() => _mockHttp.reset());

  final repo = AuthRepository();

  test('detectServerCapabilities: openSubsonic=true', () async {
    _setResponder();
    final caps = await repo.detectServerCapabilities('http://host:4040');
    expect(caps.isOpenSubsonic, isTrue);
    expect(caps.serverType, 'Navidrome');
    expect(caps.serverVersion, '0.50.0');
    expect(caps.supportsApiKey, isTrue);
  });

  test('detectServerCapabilities: openSubsonic=false', () async {
    _setResponder();
    // 用独立 responder 强制 openSubsonic=false
    _mockHttp.responder = (m, url) => (
      200,
      _okBody(openSubsonic: false, withExtensions: false),
    );
    final caps = await repo.detectServerCapabilities('http://host:4040');
    expect(caps.isOpenSubsonic, isFalse);
    expect(caps.supportsApiKey, isFalse);
  });

  test('loginWithPassword: 成功构建库', () async {
    _setResponder();
    final res = await repo.loginWithPassword(
      serverUrl: 'http://host:4040',
      username: 'u',
      password: 'p',
      libraryName: 'My Lib',
      addressLabel: 'Home',
    );
    expect(res.success, isTrue);
    expect(res.library, isNotNull);
    final lib = res.library!;
    expect(lib.name, 'My Lib');
    expect(lib.isOpenSubsonic, isTrue);
    expect(lib.addresses.length, 1);
    expect(lib.addresses.first.label, 'Home');
    expect(lib.extensions['serverFingerprint'], isNotNull);
    expect(lib.extensions['supported'], isA<List>());
  });

  test('loginWithApiKey: 成功构建库', () async {
    _setResponder();
    final res = await repo.loginWithApiKey(
      serverUrl: 'http://host:4040',
      username: 'u',
      apiKey: 'key',
    );
    expect(res.success, isTrue);
    expect(res.library, isNotNull);
    expect(res.library!.addresses.length, 1);
  });

  test('loginWithPassword: ping 失败 -> success=false', () async {
    _setResponder(pingOk: false);
    final res = await repo.loginWithPassword(
      serverUrl: 'http://host:4040',
      username: 'u',
      password: 'p',
    );
    expect(res.success, isFalse);
    expect(res.errorMessage, isNotNull);
  });

  test('loginWithPassword: 库名/地址标签缺省值', () async {
    _setResponder();
    final res = await repo.loginWithPassword(
      serverUrl: 'http://host:4040',
      username: 'u',
      password: 'p',
    );
    expect(res.success, isTrue);
    // 库名缺省回退到 serverType
    expect(res.library!.name, 'Navidrome');
    // 地址标签缺省回退到 Primary
    expect(res.library!.addresses.first.label, 'Primary');
  });

  test('verifyServerIdentity: 同 URL 直接视为同一服务器', () async {
    _setResponder();
    final existing = _lib(addresses: [_addr('http://same:4040')]);
    final ok = await repo.verifyServerIdentity(
      _addr('http://same:4040'),
      existing,
    );
    expect(ok, isTrue);
  });

  test('verifyServerIdentity: 指纹一致 -> 同一服务器', () async {
    _setResponder(
      foldersByHost: {
        'newhost': const [
          {'id': '1', 'name': 'Music'},
          {'id': '2', 'name': 'Movies'},
        ],
        'oldhost': const [
          {'id': '1', 'name': 'Music'},
          {'id': '2', 'name': 'Movies'},
        ],
      },
    );
    final existing = _lib(
      username: 'u',
      addresses: [_addr('http://oldhost:4040', priority: 0, id: 'old')],
    );
    final ok = await repo.verifyServerIdentity(
      _addr('http://newhost:4040', id: 'new'),
      existing,
    );
    expect(ok, isTrue);
  });

  test('verifyServerIdentity: 指纹不一致 -> 非同一服务器', () async {
    _setResponder(
      foldersByHost: {
        'newhost': const [
          {'id': '3', 'name': 'A'},
          {'id': '4', 'name': 'B'},
        ],
        'oldhost': const [
          {'id': '1', 'name': 'Music'},
          {'id': '2', 'name': 'Movies'},
        ],
      },
    );
    final existing = _lib(
      username: 'u',
      addresses: [_addr('http://oldhost:4040', priority: 0, id: 'old')],
    );
    final ok = await repo.verifyServerIdentity(
      _addr('http://newhost:4040', id: 'new'),
      existing,
    );
    expect(ok, isFalse);
  });

  test('verifyServerIdentity: ping 失败 -> 非同一服务器', () async {
    _setResponder(pingOk: false);
    final existing = _lib(
      username: 'u',
      addresses: [_addr('http://newhost:4040')],
    );
    final ok = await repo.verifyServerIdentity(
      _addr('http://newhost:4040'),
      existing,
    );
    expect(ok, isFalse);
  });

  test('verifyServerIdentity: 旧线路不可达 + 历史指纹匹配 -> 同一服务器', () async {
    // newhost 取指纹成功（默认两文件夹 -> 'user:u|folder:1:Music|folder:2:Movies|'），
    // oldhost ping 失败，故走历史指纹回退；历史指纹与计算值一致 -> 同一服务器。
    _setResponder(pingFailHosts: {'oldhost'});
    final fp = 'user:u|folder:1:Music|folder:2:Movies|';
    final existing = _lib(
      username: 'u',
      addresses: [_addr('http://oldhost:4040', priority: 0, id: 'old')],
      extensions: {'serverFingerprint': fp},
    );
    final ok = await repo.verifyServerIdentity(
      _addr('http://newhost:4040', id: 'new'),
      existing,
    );
    expect(ok, isTrue);
  });

  test('verifyServerIdentity: 旧线路不可达 + 无历史指纹 -> 非同一服务器', () async {
    _setResponder(pingFailHosts: {'oldhost'});
    final existing = _lib(
      username: 'u',
      addresses: [_addr('http://oldhost:4040', priority: 0, id: 'old')],
      extensions: const {},
    );
    final ok = await repo.verifyServerIdentity(
      _addr('http://newhost:4040', id: 'new'),
      existing,
    );
    expect(ok, isFalse);
  });

  // 注：_computeServerFingerprint / _normalizeUrl / _getFingerprintSourceAddress
  // 为私有方法，无法跨库直接调用；上述 verifyServerIdentity 与 loginWithPassword
  // 用例已在内部覆盖它们（226/228/241/159/235 行）。
}
