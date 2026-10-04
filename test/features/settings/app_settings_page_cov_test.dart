// 设置页（app_settings_page.dart）覆盖补测 —— batch23。
//
// 只测页面层：`lib/` 产品代码零改动，所有外部依赖（资料库仓库、地址池、
// 桌面歌词控制器、GitHub Release 网络、url_launcher、SharedPreferences）
// 全部换成桩，页面里每个 `ref.read(...)` 的副作用都能在测试里回读断言。
//
// 本批踩过的坑（编号 `#73-B`，与并行批次 `#73` 区分）：
// #73-B 页面里有 Ticker 呼吸动画（骨架屏 / 按压态），`pumpAndSettle` 永远等不到
//   「静」，实测直接 timeout。全文件统一用 `settle()` = 固定 5 帧 × 60ms。
// #74-B `UpdateChecker.check()` 是静态方法，mocktail 打不了桩；它内部用 dio
//   走真实网络。这里用 `HttpOverrides.global` 注入一个**纯内存**的假
//   `HttpClient`（不碰真 socket，FakeAsync 下才不会挂死），把 GitHub
//   Releases 的响应完全钉死。
// #75-B dart:io 的 `HttpClient` / `HttpClientRequest` / `HttpClientResponse` /
//   `HttpHeaders` 都不是可继承的（只有 factory 构造），只能 `implements`
//   逐个成员手写；dio 只用到 `connectionTimeout=/openUrl/close` 与
//   `headers.set/followRedirects/maxRedirects/persistentConnection/close()`，
//   其余成员一律 `UnimplementedError`。
// #76-B `isWindowsDesktop` 看的是 `defaultTargetPlatform`，而
//   `debugDefaultTargetPlatformOverride` 是可写的 —— 所以「桌面歌词开关」和
//   Windows 风格的更新弹窗这两条平台分支在 Linux 测试机上也能跑到，
//   但必须在 tearDown 里还原成 null，否则污染后续用例。
// #77-B `context.push('/library/edit/:id')` 需要树里有 GoRouter，裸
//   MaterialApp 会直接抛 "No GoRouter found in context"；跳转类用例走
//   `MaterialApp.router`。`_pushPage()` 用的是普通 Navigator，不需要。
// #78-B 断言落盘一律**回读真实 SharedPreferences**（经 `LocalStorage.getXxx()`），
//   而不是只看 UI 变了；`LocalStorage` 走的是 prefs 而不是 JsonFileStore。
// #79-B `librariesProvider` 的 loading 态不能用 `Stream.empty()`（会立刻 done，
//   riverpod 表现不稳定），用一个永不发射的 `StreamController` 才是确定的
//   `AsyncLoading`。
// #80-B `tester.pump()` 在本版 flutter 只收 `Duration`，`pump(Offset)` 编译不过。
// #81-B 页面主体是长 `ListView`，默认 800×600 测试视口只构建可见行，靠下的
//   「自动播放 / 记录日志 / 检查更新 / 关于」根本不在树里 —— 必须先把视口拉高。
// #82-B `MusicFlowSettingRow` 把 value 与 description 拼进**同一个** Text，
//   断言行内文案只能用 `find.textContaining`，`find.text` 永远 0 命中。
// #83-B push 子页后设置页被盖住，再 tap 它的行会「not hit testable」，
//   跳转类断言必须一例一行。
// #84-B `debugDefaultTargetPlatformOverride` 必须在**用例体结束前**还原成 null：
//   flutter_test 的 `_verifyInvariants` 先于 addTearDown 执行，晚了就报
//   "The value of a foundation debug variable was changed by the test"。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/features/settings/pages/app_settings_page.dart';
import 'package:musicflow_client/features/settings/pages/audio_quality_page.dart';
import 'package:musicflow_client/features/settings/pages/cover_providers_page.dart';
import 'package:musicflow_client/features/settings/pages/language_settings_page.dart';
import 'package:musicflow_client/features/settings/pages/log_viewer_page.dart';
import 'package:musicflow_client/features/settings/pages/lyrics_providers_page.dart';
import 'package:musicflow_client/features/settings/pages/offline_cache_page.dart';
import 'package:musicflow_client/features/settings/pages/theme_settings_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_dwell_provider.dart';
import 'package:musicflow_client/providers/media/status_lyrics_provider.dart';
import 'package:musicflow_client/providers/player/crossfade_provider.dart';
import 'package:musicflow_client/providers/ui/locale_provider.dart';
import 'package:musicflow_client/providers/ui/theme_provider.dart';

// ---------------------------------------------------------------------------
// 桩：产品侧仓库 / 控制器
// ---------------------------------------------------------------------------

class FakeLibraryRepository extends Mock implements LibraryRepository {}

class FakeAuthRepository extends Mock implements AuthRepository {}

class FakeStatusLyricsController extends Mock
    implements StatusLyricsController {}

// ---------------------------------------------------------------------------
// 桩：dart:io HttpClient（给 dio 用，见踩坑 #74-B / #75-B）
// ---------------------------------------------------------------------------

/// 假响应装配台：测试里只改这里的字段，`_FakeHttpClient` 会照着吐响应。
class FakeHttpState {
  final List<String> calls = <String>[];
  int statusCode = 200;
  String body = '{}';
  Object? failWith;

  /// 非空时 `openUrl` 会先等它 —— 用来把「检查中」的中间态钉住。
  Future<void>? gate;

  List<int> get bodyBytes => utf8.encode(body);

  void reset() {
    calls.clear();
    statusCode = 200;
    body = '{}';
    failWith = null;
    gate = null;
  }
}

final FakeHttpState fakeHttp = FakeHttpState();

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
  ]) => throw UnimplementedError();
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.owner);

  final FakeHttpState owner;

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
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) {}

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
  Future<HttpClientRequest> open(String method, String host, int port, String path) =>
      openUrl(method, Uri(host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    owner.calls.add('$method $url');
    final gate = owner.gate;
    if (gate != null) await gate;
    final failure = owner.failWith;
    if (failure != null) throw failure;
    return _FakeRequest(method, url)
      ..responseStatus = owner.statusCode
      ..responseBody = owner.bodyBytes;
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
      _FakeHttpClient(fakeHttp);
}

// ---------------------------------------------------------------------------
// 测试数据
// ---------------------------------------------------------------------------

const String kLibA = 'lib-a';
const String kLibB = 'lib-b';
const String kLibC = 'lib-c';

MusicLibrary libraryOf(
  String id,
  String name, {
  MusicLibraryAuthType authType = MusicLibraryAuthType.token,
  String? username,
  bool isActive = false,
  List<ServerAddress> addresses = const <ServerAddress>[],
}) {
  return MusicLibrary(
    id: id,
    name: name,
    username: username,
    authType: authType,
    isActive: isActive,
    addresses: addresses,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

ServerAddress addressOf(
  String id,
  String libraryId, {
  String label = '家庭',
  String url = 'https://home.example.com',
}) {
  return ServerAddress(id: id, libraryId: libraryId, label: label, url: url, priority: 0);
}

/// 资料库列表流的三种形态。
enum LibMode { data, loading, error }

// ---------------------------------------------------------------------------
// 全局装配台
// ---------------------------------------------------------------------------

/// 页面里所有 `ref.watch` 的 provider 都在这里换桩，见踩坑 #78-B。
LibMode libMode = LibMode.data;
List<MusicLibrary> libValue = <MusicLibrary>[];
Object libError = StateError('library stream boom');
StreamController<List<MusicLibrary>>? libController;
int libSubscribeCount = 0;

List<MusicLibrary> authLibraries = <MusicLibrary>[];
ServerAddress? activeAddress;
bool autoFallback = true;
bool statusLyrics = false;

FakeLibraryRepository? repo;
FakeStatusLyricsController? lyricsCtrl;
AddressPool? pool;
ProviderContainer? container;
AppLocalizations? loc;

/// 主题里的 error 色，用来把「列表读取失败」行尾的刷新图标和「检查更新」行的
/// 同名图标区分开（两者都用 `AppIcons.refresh`）。
Color? errorColor;

const MethodChannel _pkgInfoChannel = MethodChannel(
  'dev.fluttercommunity.plus/package_info',
);
const MethodChannel _launcherChannel = MethodChannel(
  'plugins.flutter.io/url_launcher',
);
const MethodChannel _pathProviderChannel = MethodChannel(
  'plugins.flutter.io/path_provider',
);

String pkgInfoVersion = '1.0.0';
bool pkgInfoThrows = false;
final List<String> launchedUrls = <String>[];

/// 页面里 Ticker 呼吸动画不断请求新帧，`pumpAndSettle` 永远等不到静
/// （踩坑 #73-B），统一用固定帧推进。
Future<void> settle(WidgetTester tester, {int frames = 5}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 在页面里捞一份 `AppLocalizations`，断言文案就不必硬编码中文。
class _LocProbe extends StatelessWidget {
  const _LocProbe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    loc = AppLocalizations.of(context);
    errorColor = context.musicFlowColors.error;
    return child;
  }
}

/// 页面主体是一个长 `ListView`，默认 800×600 的测试视口**只会构建可见的那几行**
/// （踩坑 #81-B）——「自动播放 / 记录日志 / 检查更新 / 关于」这些靠下的行根本不在
/// 树里，`find.text` 一律 0 命中。把视口拉高到 1000×2600 让整页一次铺开。
void enlargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1.0;
}

Future<ProviderContainer> pumpPage(WidgetTester tester) async {
  enlargeViewport(tester);
  final c = ProviderContainer(
    overrides: <Override>[
      libraryRepositoryProvider.overrideWithValue(repo!),
      authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
      authStateProvider.overrideWith(
        (ref) => AuthNotifier(FakeAuthRepository(), repo!),
      ),
      librariesProvider.overrideWith((ref) {
        libSubscribeCount++;
        switch (libMode) {
          case LibMode.data:
            return Stream<List<MusicLibrary>>.value(libValue);
          case LibMode.loading:
            return (libController ??= StreamController<List<MusicLibrary>>())
                .stream;
          case LibMode.error:
            return Stream<List<MusicLibrary>>.error(libError);
        }
      }),
      activeAddressProvider.overrideWith((ref) => activeAddress),
      autoFallbackProvider.overrideWith((ref) => autoFallback),
      addressPoolProvider.overrideWithValue(pool!),
      statusLyricsEnabledProvider.overrideWith((ref) => statusLyrics),
      statusLyricsControllerProvider.overrideWithValue(lyricsCtrl!),
    ],
  );
  container = c;
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: const _LocProbe(child: AppSettingsPage()),
      ),
    ),
  );
  await settle(tester);
  return c;
}

/// 需要 go_router 的用例（「编辑资料库」走 `context.push`），见踩坑 #77-B。
Future<ProviderContainer> pumpPageWithRouter(WidgetTester tester) async {
  enlargeViewport(tester);
  final c = ProviderContainer(
    overrides: <Override>[
      libraryRepositoryProvider.overrideWithValue(repo!),
      authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
      authStateProvider.overrideWith(
        (ref) => AuthNotifier(FakeAuthRepository(), repo!),
      ),
      librariesProvider.overrideWith((ref) {
        libSubscribeCount++;
        return Stream<List<MusicLibrary>>.value(libValue);
      }),
      activeAddressProvider.overrideWith((ref) => activeAddress),
      autoFallbackProvider.overrideWith((ref) => autoFallback),
      addressPoolProvider.overrideWithValue(pool!),
      statusLyricsEnabledProvider.overrideWith((ref) => statusLyrics),
      statusLyricsControllerProvider.overrideWithValue(lyricsCtrl!),
    ],
  );
  container = c;
  addTearDown(c.dispose);
  final router = GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, __) => const _LocProbe(child: AppSettingsPage()),
        routes: <RouteBase>[
          GoRoute(
            path: 'library/edit/:id',
            builder: (_, state) => Scaffold(
              body: Text('edit-page:${state.pathParameters['id']}'),
            ),
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
      ),
    ),
  );
  await settle(tester);
  return c;
}

/// GitHub Releases API 的响应体。
String releaseJson({
  required String tag,
  String? body,
  String? htmlUrl,
  List<Map<String, Object?>> assets = const <Map<String, Object?>>[],
}) {
  return jsonEncode(<String, Object?>{
    'tag_name': tag,
    // 不给默认值：留 null 才能走到「发布页 URL 为 null」那半条判断。
    'html_url': htmlUrl,
    'body': body,
    'assets': assets,
  });
}

const Map<String, Object?> kWinAsset = <String, Object?>{
  'name': 'MusicFlow-v2.0.0-windows-setup.exe',
  'browser_download_url': 'https://example.test/dl/windows-setup.exe',
  'size': 3 * 1024 * 1024,
};

const Map<String, Object?> kZipAsset = <String, Object?>{
  'name': 'MusicFlow-v2.0.0-linux.zip',
  'browser_download_url': 'https://example.test/dl/linux.zip',
  'size': 1024 * 1024,
};

/// 点「检查更新」并等它跑完（含 dio 链路的几跳微任务）。
Future<void> tapCheckUpdate(WidgetTester tester) async {
  await tester.tap(find.text(loc!.settings_check_update));
  await settle(tester, frames: 12);
}

// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final tempDir = Directory.systemTemp.createTempSync('b23_settings');

  setUpAll(() {
    HttpOverrides.global = _FakeHttpOverrides();
  });

  setUp(() {
    fakeHttp.reset();
    launchedUrls.clear();
    pkgInfoVersion = '1.0.0';
    pkgInfoThrows = false;

    libMode = LibMode.data;
    libValue = <MusicLibrary>[];
    libError = StateError('library stream boom');
    libController = null;
    libSubscribeCount = 0;
    authLibraries = <MusicLibrary>[];
    activeAddress = null;
    autoFallback = true;
    statusLyrics = false;
    loc = null;
    errorColor = null;
    Logger.setLoggingEnabled(false);

    repo = FakeLibraryRepository();
    lyricsCtrl = FakeStatusLyricsController();
    pool = AddressPool(
      Dio(),
      onAddressUpdated: (_) {},
      onActiveAddressChanged: (_) {},
    );
    when(() => repo!.watchLibraries()).thenAnswer(
      (_) => Stream<List<MusicLibrary>>.value(authLibraries),
    );
    when(() => repo!.setActiveLibrary(any())).thenAnswer((_) async {});
    when(() => lyricsCtrl!.toggle()).thenAnswer((_) async {});

    SharedPreferences.setMockInitialValues(<String, Object>{});

    // package_info_plus：没它 `UpdateChecker.check()` 在 `PackageInfo.fromPlatform`
    // 就炸（在 try 之外），只会走到「检查更新失败」分支。
    _pkgInfoChannel.setMockMethodCallHandler((MethodCall call) async {
      if (pkgInfoThrows) throw MissingPluginException('no package_info');
      return <String, dynamic>{
        'appName': 'MusicFlow',
        'packageName': 'com.musicflow.client',
        'version': pkgInfoVersion,
        'buildNumber': '1',
        'buildSignature': '',
        'installerStore': null,
      };
    });
    _launcherChannel.setMockMethodCallHandler((MethodCall call) async {
      if (call.method == 'canLaunch') return true;
      if (call.method == 'launch') {
        final args = call.arguments as Map<dynamic, dynamic>?;
        launchedUrls.add('${args?['url']}');
        return true;
      }
      return null;
    });
    _pathProviderChannel.setMockMethodCallHandler((MethodCall call) async {
      return tempDir.path;
    });
  });

  tearDown(() {
    _pkgInfoChannel.setMockMethodCallHandler(null);
    _launcherChannel.setMockMethodCallHandler(null);
    _pathProviderChannel.setMockMethodCallHandler(null);
  });

  // =========================================================================
  group('资料库区块：librariesAsync 三态', () {
    testWidgets('01 三个资料库 → 描述显示数量，切换行无骨架屏', (tester) async {
      libValue = <MusicLibrary>[
        libraryOf(kLibA, 'A库', isActive: true),
        libraryOf(kLibB, 'B库'),
        libraryOf(kLibC, 'C库'),
      ];
      authLibraries = libValue;
      await pumpPage(tester);

      // 行内 value + description 会拼成一个 Text（'A库 · 已保存 3 个音乐库'），
      // 只能用 textContaining（踩坑 #82-B）。
      expect(find.textContaining(loc!.settings_library_count_saved(3)), findsOneWidget);
      expect(find.byType(MusicFlowSkeleton), findsNothing);
      expect(find.text(loc!.settings_switch_library), findsOneWidget);
    });

    testWidgets('02 单个资料库 → 显示「仅有一个」文案', (tester) async {
      libValue = <MusicLibrary>[libraryOf(kLibA, 'A库', isActive: true)];
      authLibraries = libValue;
      await pumpPage(tester);

      expect(find.textContaining(loc!.settings_library_single), findsOneWidget);
      expect(find.text(loc!.settings_library_count_saved(1)), findsNothing);
    });

    testWidgets('03 空列表 → 空态文案且切换行不可点', (tester) async {
      libValue = <MusicLibrary>[];
      authLibraries = libValue;
      await pumpPage(tester);

      expect(find.textContaining(loc!.settings_library_empty), findsOneWidget);
      await tester.tap(find.text(loc!.settings_switch_library));
      await settle(tester);
      // onPressed 为 null → 不会弹出切换抽屉。
      expect(find.text(loc!.settings_library_switch_subtitle), findsNothing);
    });

    testWidgets('04 loading → 骨架屏占位 + 加载中文案', (tester) async {
      libMode = LibMode.loading;
      libValue = <MusicLibrary>[libraryOf(kLibA, 'A库', isActive: true)];
      authLibraries = libValue;
      await pumpPage(tester);

      expect(find.textContaining(loc!.settings_library_loading), findsOneWidget);
      expect(find.byType(MusicFlowSkeleton), findsOneWidget);
    });

    testWidgets('05 error → 重试图标 + 失败文案，点击触发 invalidate', (tester) async {
      libMode = LibMode.error;
      authLibraries = <MusicLibrary>[libraryOf(kLibA, 'A库', isActive: true)];
      await pumpPage(tester);

      expect(find.textContaining(loc!.settings_library_load_failed), findsOneWidget);
      // 「检查更新」行也用 AppIcons.refresh，靠尺寸 + error 色把两者分开。
      final refreshIcons = tester.widgetList<Icon>(find.byIcon(AppIcons.refresh));
      expect(
        refreshIcons.where((i) => i.size == 20 && i.color == errorColor).length,
        1,
      );
      expect(libSubscribeCount, 1);

      await tester.tap(find.text(loc!.settings_switch_library));
      await settle(tester);
      // 该行在 error 分支下绑定 ref.invalidate(librariesProvider) →
      // 流会被重新订阅一次。去掉 invalidate 这条就会红。
      expect(libSubscribeCount, 2);
    });
  });

  // =========================================================================
  group('切换资料库抽屉', () {
    testWidgets('06 抽屉列出全部资料库并显示当前库', (tester) async {
      libValue = <MusicLibrary>[
        libraryOf(kLibA, 'A库', isActive: true),
        libraryOf(kLibB, 'B库'),
      ];
      authLibraries = libValue;
      await pumpPage(tester);

      await tester.tap(find.text(loc!.settings_switch_library));
      await settle(tester);

      expect(find.text(loc!.settings_library_switch_subtitle), findsOneWidget);
      expect(find.text('A库'), findsWidgets);
      expect(find.text('B库'), findsOneWidget);
    });

    testWidgets('07 选中另一个库 → 落库 + 切 authState + 成功提示', (tester) async {
      libValue = <MusicLibrary>[
        libraryOf(kLibA, 'A库', isActive: true),
        libraryOf(kLibB, 'B库'),
      ];
      authLibraries = libValue;
      final c = await pumpPage(tester);
      expect(c.read(authStateProvider).currentLibrary?.id, kLibA);

      await tester.tap(find.text(loc!.settings_switch_library));
      await settle(tester);
      await tester.tap(find.text('B库'));
      await settle(tester, frames: 10);

      verify(() => repo!.setActiveLibrary(kLibB)).called(1);
      expect(c.read(authStateProvider).currentLibrary?.id, kLibB);
      expect(
        find.textContaining(loc!.settings_library_switched('B库')),
        findsOneWidget,
      );
    });

    testWidgets('08 选中当前库 → 不再调用 setActiveLibrary', (tester) async {
      libValue = <MusicLibrary>[
        libraryOf(kLibA, 'A库', isActive: true),
        libraryOf(kLibB, 'B库'),
      ];
      authLibraries = libValue;
      await pumpPage(tester);

      await tester.tap(find.text(loc!.settings_switch_library));
      await settle(tester);
      // 'A库' 同时出现在设置页行与抽屉里，取抽屉（树中靠后）那一个。
      await tester.tap(find.text('A库').last);
      await settle(tester, frames: 10);

      verifyNever(() => repo!.setActiveLibrary(any()));
      expect(find.text(loc!.settings_library_switch_subtitle), findsNothing);
    });

    testWidgets('09 setActiveLibrary 抛错 → 失败提示', (tester) async {
      libValue = <MusicLibrary>[
        libraryOf(kLibA, 'A库', isActive: true),
        libraryOf(kLibB, 'B库'),
      ];
      authLibraries = libValue;
      when(() => repo!.setActiveLibrary(any())).thenThrow(StateError('db down'));
      await pumpPage(tester);

      await tester.tap(find.text(loc!.settings_switch_library));
      await settle(tester);
      await tester.tap(find.text('B库'));
      await settle(tester, frames: 10);

      expect(
        find.textContaining(loc!.settings_library_switch_failed('').trim()),
        findsOneWidget,
      );
    });
  });

  // =========================================================================
  group('_ServerSummary', () {
    testWidgets('10 有库有地址 → 逐行展示库/连接/地址/用户名/鉴权', (tester) async {
      final addr = addressOf('a1', kLibA, label: '书房', url: 'https://s.example.com');
      libValue = <MusicLibrary>[
        libraryOf(kLibA, 'A库', isActive: true, username: 'alice', addresses: <ServerAddress>[addr]),
      ];
      authLibraries = libValue;
      activeAddress = addr;
      await pumpPage(tester);

      expect(find.text('A库'), findsWidgets);
      expect(find.text('书房'), findsOneWidget);
      expect(find.text('https://s.example.com'), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
      expect(find.text(loc!.settings_auth_password), findsOneWidget);
      expect(find.text('API Key'), findsNothing);
    });

    testWidgets('11 apiKey 鉴权 → 显示 API Key', (tester) async {
      libValue = <MusicLibrary>[
        libraryOf(kLibA, 'A库', isActive: true, authType: MusicLibraryAuthType.apiKey, username: 'bob'),
      ];
      authLibraries = libValue;
      await pumpPage(tester);

      expect(find.text('API Key'), findsOneWidget);
      expect(find.text(loc!.settings_auth_password), findsNothing);
    });

    testWidgets('12 无库无地址 → 四项占位文案', (tester) async {
      libValue = <MusicLibrary>[];
      authLibraries = libValue;
      activeAddress = null;
      await pumpPage(tester);

      expect(find.text(loc!.settings_not_selected), findsWidgets);
      expect(find.text(loc!.settings_not_connected), findsOneWidget);
      expect(find.text(loc!.settings_not_set), findsNWidgets(2));
    });
  });

  // =========================================================================
  group('编辑资料库跳转', () {
    testWidgets('13 未选库 → 空态描述且点击不跳转', (tester) async {
      libValue = <MusicLibrary>[];
      authLibraries = libValue;
      await pumpPageWithRouter(tester);

      expect(find.textContaining(loc!.settings_edit_library_empty_desc), findsOneWidget);
      await tester.tap(find.text(loc!.settings_edit_library));
      await settle(tester);
      expect(find.textContaining('edit-page:'), findsNothing);
    });

    testWidgets('14 已选库 → context.push 到 /library/edit/:id', (tester) async {
      libValue = <MusicLibrary>[libraryOf(kLibA, 'A库', isActive: true)];
      authLibraries = libValue;
      await pumpPageWithRouter(tester);

      await tester.tap(find.text(loc!.settings_edit_library));
      await settle(tester, frames: 10);

      expect(find.text('edit-page:$kLibA'), findsOneWidget);
    });
  });

  // =========================================================================
  group('播放区块：开关与联动落盘', () {
    testWidgets('15 自动回退开关 → provider + 地址池 + prefs 三处同步', (tester) async {
      autoFallback = true;
      await pumpPage(tester);
      final c = container!;
      expect(c.read(autoFallbackProvider), isTrue);
      expect(pool!.autoFallback, isTrue);

      await tester.tap(find.text(loc!.settings_route_auto_fallback));
      await settle(tester);

      expect(c.read(autoFallbackProvider), isFalse);
      expect(pool!.autoFallback, isFalse);
      // 回读真实 SharedPreferences，而不是只看 UI（踩坑 #78-B）。
      expect(await LocalStorage.getAutoFallback(), isFalse);
    });

    testWidgets('16 自动回退从 false 拨回 true 也会落盘', (tester) async {
      // `LocalStorage.getAutoFallback()` 缺省为 true，所以 false 的初值必须
      // 真的写进 prefs，回读断言才有意义。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'auto_fallback': false,
      });
      autoFallback = false;
      await pumpPage(tester);
      expect(await LocalStorage.getAutoFallback(), isFalse);

      await tester.tap(find.text(loc!.settings_route_auto_fallback));
      await settle(tester);

      expect(container!.read(autoFallbackProvider), isTrue);
      expect(pool!.autoFallback, isTrue);
      expect(await LocalStorage.getAutoFallback(), isTrue);
    });

    testWidgets('17 主题行显示「模式 · #RRGGBB」并可跳主题页', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'theme_mode': 'dark',
        'theme_seed_color': 0xFF12A05C,
      });
      await pumpPage(tester);

      expect(find.textContaining('${loc!.settings_theme_mode_dark} · #12A05C'), findsOneWidget);
      await tester.tap(find.text(loc!.settings_theme));
      await settle(tester, frames: 10);
      expect(find.byType(ThemeSettingsPage), findsOneWidget);
    });

    testWidgets('17b 主题为浅色时显示「浅色」文案', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'theme_mode': 'light',
      });
      await pumpPage(tester);

      expect(
        find.textContaining(loc!.settings_theme_mode_light),
        findsOneWidget,
      );
      expect(find.textContaining(loc!.settings_theme_mode_dark), findsNothing);
    });

    testWidgets('18 语言行三种偏好文案 + 跳转语言页', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'app_language': 'en',
      });
      await pumpPage(tester);

      expect(find.textContaining(loc!.language_en), findsOneWidget);
      await tester.tap(find.text(loc!.settings_language));
      await settle(tester, frames: 10);
      expect(find.byType(LanguageSettingsPage), findsOneWidget);
    });

    // 四个跳转行各自单独成例：push 之后设置页被盖在下面，再 tap 它的行就不是
    // hit-testable 了（踩坑 #83-B）。
    testWidgets('19 音质行 → push AudioQualityPage', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text(loc!.settings_audio_quality));
      await settle(tester, frames: 10);
      expect(find.byType(AudioQualityPage), findsOneWidget);
    });

    testWidgets('19b 离线缓存行 → push OfflineCachePage', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text(loc!.offline_cache_title));
      await settle(tester, frames: 10);
      expect(find.byType(OfflineCachePage), findsOneWidget);
    });

    testWidgets('19c 歌词源行 → push LyricsProvidersPage', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text(loc!.settings_lyrics_provider));
      await settle(tester, frames: 10);
      expect(find.byType(LyricsProvidersPage), findsOneWidget);
    });

    testWidgets('19d 封面源行 → push CoverProvidersPage', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text(loc!.settings_cover_provider));
      await settle(tester, frames: 10);
      expect(find.byType(CoverProvidersPage), findsOneWidget);
    });

    testWidgets('20 淡入淡出：值标签 + 抽屉选值落盘', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'crossfade_duration_ms': 1500,
      });
      final c = await pumpPage(tester);
      expect(c.read(crossfadeDurationMsProvider), 1500);
      expect(
        find.textContaining(loc!.settings_crossfade_seconds('1.5')),
        findsOneWidget,
      );

      await tester.tap(find.text(loc!.settings_crossfade));
      await settle(tester);
      expect(find.text(loc!.settings_crossfade_subtitle), findsOneWidget);

      await tester.tap(find.text(loc!.settings_crossfade_seconds('2.0')));
      await settle(tester, frames: 10);

      expect(c.read(crossfadeDurationMsProvider), 2000);
      expect(await LocalStorage.getCrossfadeDurationMs(), 2000);
    });

    testWidgets('21 淡入淡出为 0 时显示「关闭」，抽屉里选 0 亦落盘', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'crossfade_duration_ms': 0,
      });
      final c = await pumpPage(tester);
      expect(find.textContaining(loc!.settings_crossfade_off), findsWidgets);

      await tester.tap(find.text(loc!.settings_crossfade));
      await settle(tester);
      await tester.tap(find.text(loc!.settings_crossfade_seconds('2.5')));
      await settle(tester, frames: 10);

      expect(c.read(crossfadeDurationMsProvider), 2500);
      expect(await LocalStorage.getCrossfadeDurationMs(), 2500);
    });

    testWidgets('22 歌词停靠：抽屉选值落盘 + 值标签回显', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lyrics_scroll_dwell_seconds': 3,
      });
      final c = await pumpPage(tester);
      expect(c.read(lyricsScrollDwellProvider), 3);
      expect(find.textContaining(loc!.settings_dwell_seconds('3')), findsOneWidget);

      await tester.tap(find.text(loc!.settings_lyrics_dwell));
      await settle(tester);
      expect(find.text(loc!.settings_lyrics_dwell_subtitle), findsOneWidget);

      await tester.tap(find.text(loc!.settings_dwell_seconds('8')));
      await settle(tester, frames: 10);

      expect(c.read(lyricsScrollDwellProvider), 8);
      expect(await LocalStorage.getLyricsScrollDwellSeconds(), 8);
    });

    testWidgets('23 启动自动播放：读盘初始化 + 切换落盘', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'auto_play_on_launch': true,
      });
      await pumpPage(tester);
      expect(await LocalStorage.getAutoPlayOnLaunch(), isTrue);

      await tester.tap(find.text(loc!.settings_autoplay));
      await settle(tester);
      expect(await LocalStorage.getAutoPlayOnLaunch(), isFalse);

      await tester.tap(find.text(loc!.settings_autoplay));
      await settle(tester);
      expect(await LocalStorage.getAutoPlayOnLaunch(), isTrue);
    });

    testWidgets('24 日志开关：落盘 + 同步 Logger 全局状态', (tester) async {
      await pumpPage(tester);
      expect(Logger.loggingEnabled, isFalse);

      await tester.tap(find.text(loc!.settings_logging));
      await settle(tester);

      expect(await LocalStorage.getLoggingEnabled(), isTrue);
      expect(Logger.loggingEnabled, isTrue);
    });

    testWidgets('25 日志开关初始从 prefs 读回 true', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'logging_enabled': true,
      });
      await pumpPage(tester);
      expect(Logger.loggingEnabled, isTrue);

      await tester.tap(find.text(loc!.settings_logging));
      await settle(tester);
      expect(await LocalStorage.getLoggingEnabled(), isFalse);
      expect(Logger.loggingEnabled, isFalse);
    });
  });

  // =========================================================================
  group('平台分支：Windows 桌面歌词开关', () {
    testWidgets('26 Windows 下出现桌面歌词开关且点击走 toggle()', (tester) async {
      // 踩坑 #76-B：defaultTargetPlatform 可写，Linux 测试机也能进 Windows 分支。
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        statusLyrics = false;
        await pumpPage(tester);

        expect(find.text(loc!.settings_desktop_lyrics), findsOneWidget);
        await tester.tap(find.text(loc!.settings_desktop_lyrics));
        await settle(tester);

        verify(() => lyricsCtrl!.toggle()).called(1);
      } finally {
        // 必须在**用例体结束前**还原：flutter_test 的 `_verifyInvariants`
        // 先于 addTearDown 跑，晚一步就会报 "foundation debug variable 被改"。
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('27 非 Windows 平台不渲染桌面歌词开关', (tester) async {
      statusLyrics = true;
      await pumpPage(tester);

      expect(find.text(loc!.settings_desktop_lyrics), findsNothing);
      verifyNever(() => lyricsCtrl!.toggle());
    });
  });

  // =========================================================================
  group('诊断区块：检查更新', () {
    testWidgets('28 package_info 缺失 → 失败提示且按钮恢复可点', (tester) async {
      pkgInfoThrows = true;
      await pumpPage(tester);

      await tapCheckUpdate(tester);
      expect(
        find.textContaining(loc!.settings_update_check_failed('').trim()),
        findsOneWidget,
      );
      // finally 里把 _isCheckingUpdate 复位 → 骨架屏消失、行重新可点。
      expect(find.byType(MusicFlowSkeleton), findsNothing);

      await tester.tap(find.text(loc!.settings_check_update));
      await settle(tester, frames: 12);
      expect(
        find.textContaining(loc!.settings_update_check_failed('').trim()),
        findsWidgets,
      );
    });

    testWidgets('29 检查中：骨架屏占位且重复点击不再发请求', (tester) async {
      final gate = Completer<void>();
      fakeHttp.gate = gate.future;
      await pumpPage(tester);

      await tester.tap(find.text(loc!.settings_check_update));
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.byType(MusicFlowSkeleton), findsOneWidget);
      expect(fakeHttp.calls.length, 1);
      // _isCheckingUpdate 为 true 时 onPressed 传 null，再点不会发第二个请求。
      await tester.tap(find.text(loc!.settings_check_update));
      await tester.pump(const Duration(milliseconds: 60));
      expect(fakeHttp.calls.length, 1);

      gate.complete();
      await settle(tester, frames: 12);
      expect(find.byType(MusicFlowSkeleton), findsNothing);
    });

    testWidgets('30 已是最新 → 成功提示带当前版本', (tester) async {
      fakeHttp.body = releaseJson(tag: 'v1.0.0');
      await pumpPage(tester);

      await tapCheckUpdate(tester);

      expect(fakeHttp.calls.length, 1);
      expect(fakeHttp.calls.single, contains('api.github.com'));
      expect(
        find.textContaining(loc!.settings_update_latest('1.0.0')),
        findsOneWidget,
      );
    });

    testWidgets('31 网络失败 → 走 atom 兜底也失败后仍报失败', (tester) async {
      fakeHttp.failWith = const SocketException('no network');
      await pumpPage(tester);

      await tapCheckUpdate(tester);

      // 主路径 + atom 兜底各一次请求。
      expect(fakeHttp.calls.length, 2);
      expect(fakeHttp.calls.last, contains('releases.atom'));
      expect(
        find.textContaining(loc!.settings_update_check_failed('').trim()),
        findsOneWidget,
      );
    });

    testWidgets('32 发现新版本 → 弹窗含版本/说明/资源，稍后关闭不跳链接', (tester) async {
      fakeHttp.body = releaseJson(
        tag: 'v2.0.0',
        body: '修复了若干问题',
        assets: <Map<String, Object?>>[kZipAsset],
      );
      await pumpPage(tester);

      await tapCheckUpdate(tester);

      expect(find.text(loc!.settings_update_found), findsOneWidget);
      expect(find.text('1.0.0 → 2.0.0'), findsOneWidget);
      expect(find.text('2.0.0'), findsWidgets);
      expect(find.text(loc!.settings_update_notes), findsOneWidget);
      expect(find.text('修复了若干问题'), findsOneWidget);
      expect(find.text(loc!.settings_update_assets), findsOneWidget);
      expect(find.text('MusicFlow-v2.0.0-linux.zip'), findsOneWidget);
      // 1 MiB → 1.0 MB
      expect(find.text('1.0 MB'), findsOneWidget);

      await tester.tap(find.text(loc!.settings_later));
      await settle(tester, frames: 10);
      expect(find.text(loc!.settings_update_found), findsNothing);
      expect(launchedUrls, isEmpty);
    });

    testWidgets('33 点「前往下载」→ 走平台首选资源并关闭弹窗', (tester) async {
      fakeHttp.body = releaseJson(
        tag: 'v2.0.0',
        assets: <Map<String, Object?>>[kZipAsset, kWinAsset],
      );
      await pumpPage(tester);

      await tapCheckUpdate(tester);
      await tester.tap(find.text(loc!.settings_download));
      await settle(tester, frames: 12);

      expect(launchedUrls, <String>['https://example.test/dl/linux.zip']);
      expect(find.text(loc!.settings_update_found), findsNothing);
    });

    testWidgets('34 点资源行 → 直接跳该资源链接', (tester) async {
      fakeHttp.body = releaseJson(
        tag: 'v2.0.0',
        assets: <Map<String, Object?>>[kZipAsset, kWinAsset],
      );
      await pumpPage(tester);

      await tapCheckUpdate(tester);
      await tester.tap(find.text('MusicFlow-v2.0.0-windows-setup.exe'));
      await settle(tester, frames: 12);

      expect(
        launchedUrls,
        <String>['https://example.test/dl/windows-setup.exe'],
      );
    });

    testWidgets('35 无资源 → 用发布页 URL 兜底', (tester) async {
      fakeHttp.body = releaseJson(
        tag: 'v2.0.0',
        htmlUrl: 'https://example.test/release/page',
      );
      await pumpPage(tester);

      await tapCheckUpdate(tester);
      expect(find.text(loc!.settings_update_assets), findsNothing);
      expect(find.text(loc!.settings_update_notes), findsNothing);

      await tester.tap(find.text(loc!.settings_download));
      await settle(tester, frames: 12);

      expect(
        launchedUrls,
        <String>['https://example.test/release/page'],
      );
    });

    testWidgets('36 Windows 平台走桌面对话框并挑 windows-setup.exe', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        fakeHttp.body = releaseJson(
          tag: 'v2.0.0',
          assets: <Map<String, Object?>>[kZipAsset, kWinAsset],
        );
        await pumpPage(tester);

        await tapCheckUpdate(tester);
        expect(find.byType(MusicFlowDesktopDialog), findsOneWidget);
        expect(find.text('MusicFlow-v2.0.0-windows-setup.exe'), findsOneWidget);

        await tester.tap(find.text(loc!.settings_download));
        await settle(tester, frames: 12);

        expect(
          launchedUrls,
          <String>['https://example.test/dl/windows-setup.exe'],
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  // =========================================================================
  group('诊断区块：日志与关于', () {
    testWidgets('39 既无资源也无发布页链接 → 弹窗不出现「前往下载」', (tester) async {
      fakeHttp.body = releaseJson(tag: 'v2.0.0', body: '只有说明');
      await pumpPage(tester);

      await tapCheckUpdate(tester);

      expect(find.text(loc!.settings_update_found), findsOneWidget);
      expect(find.text(loc!.settings_update_assets), findsNothing);
      // 两个条件都为 false → 主按钮整块不渲染。
      expect(find.text(loc!.settings_download), findsNothing);
      expect(find.text(loc!.settings_later), findsOneWidget);

      await tester.tap(find.text(loc!.settings_later));
      await settle(tester, frames: 10);
      expect(launchedUrls, isEmpty);
    });

    testWidgets('37 查看日志 → push LogViewerPage', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text(loc!.settings_view_logs));
      await settle(tester, frames: 10);

      expect(find.byType(LogViewerPage), findsOneWidget);
    });

    testWidgets('38 关于抽屉 → 项目主页跳 GitHub', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text(loc!.settings_about));
      await settle(tester);

      expect(find.text(loc!.settings_about_title), findsOneWidget);
      expect(find.text('MusicFlow'), findsWidgets);
      expect(find.text('github.com/ray5378/MusicFlow-client'), findsOneWidget);
      expect(find.text('© 2026 MusicFlow'), findsOneWidget);

      await tester.tap(find.text(loc!.settings_project_home));
      await settle(tester, frames: 10);

      expect(
        launchedUrls,
        <String>['https://github.com/ray5378/MusicFlow-client'],
      );
    });
  });
}
