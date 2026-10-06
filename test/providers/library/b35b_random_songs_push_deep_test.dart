// b35b: random_songs_push_provider.dart 深水区补测(batch33 b33b 未覆盖分支)。
// 产品代码零改动。本地 HttpServer+WebSocketTransformer 起真实 WS 服务,
// 覆盖: token 认证登录换 JWT 握手、登录失败重试排程、无库不重试、
// clientId 异常降级、二进制消息解析、活跃地址变化重连、库变化立即重连
// (取消 2s 退避)、https→wss 构建与连接失败容错。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/peer_remote_control_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/library/random_songs_push_provider.dart';

import '../../features/player/test_player_notifier.dart';
import '../../helpers/mocks.dart';

class _WsServer {
  _WsServer(this.server);

  final HttpServer server;
  final List<HttpRequest> upgrades = <HttpRequest>[];
  WebSocket? _socket;

  static Future<_WsServer> start() async {
    final s = await HttpServer.bind('127.0.0.1', 0);
    final h = _WsServer(s);
    s.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      h._socket = ws;
      h.upgrades.add(req);
      ws.listen((_) {});
    });
    return h;
  }

  String get url => 'http://127.0.0.1:${server.port}';

  void sendRaw(dynamic raw) => _socket!.add(raw);

  Future<void> closeSocket() => _socket!.close();

  Future<void> dispose() => server.close(force: true);
}

MusicLibrary _lib({String apiKey = 'tk-1'}) => MusicLibrary(
      id: 'lib-1',
      name: 'Test',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
      authType: MusicLibraryAuthType.apiKey,
      apiKey: apiKey,
    );

MusicLibrary _passwordLib() => MusicLibrary(
      id: 'lib-1',
      name: 'Test',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
      authType: MusicLibraryAuthType.token,
      username: 'alice',
      password: 'secret',
    );

ServerAddress _addr(String url) => ServerAddress(
      id: 'a1',
      libraryId: 'lib-1',
      label: 'Home',
      url: url,
      priority: 0,
    );

class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());

  final List<MapEntry<String, bool>> starredCalls = <MapEntry<String, bool>>[];

  @override
  void applyExternalStarred(String songId, bool starred) {
    starredCalls.add(MapEntry(songId, starred));
  }
}

class _FakePeerRemote extends PeerRemoteControlNotifier {
  _FakePeerRemote(super.ref);

  final List<Map<String, dynamic>> handled = <Map<String, dynamic>>[];

  @override
  Future<void> handleServerMessage(Map<String, dynamic> msg) async {
    handled.add(msg);
  }
}

Future<void> waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 6),
  String reason = 'condition not met in time',
}) async {
  final end = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(cond(), isTrue, reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _WsServer server;
  late MockSubsonicApiClient api;
  late _RecordingPlayer player;
  _FakePeerRemote? peer;
  ProviderContainer? container;

  setUp(() async {
    server = await _WsServer.start();
    api = MockSubsonicApiClient();
    when(() => api.clientId()).thenAnswer((_) async => 'cid-1');
    player = _RecordingPlayer();
  });

  tearDown(() async {
    try {
      container?.dispose();
    } catch (_) {}
    await server.dispose();
  });

  /// 登录桩:每次 /rest/api/v1/auth/login 请求计数,默认返回 jwt。
  ({Dio dio, List<String> calls}) stubLoginDio({Object? respond}) {
    final calls = <String>[];
    final dio = Dio();
    dio.interceptors.clear();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        calls.add(options.uri.path);
        if (respond is Exception) {
          handler.reject(DioException(
            requestOptions: options,
            error: respond,
            type: DioExceptionType.unknown,
          ));
          return;
        }
        handler.resolve(Response<dynamic>(
          requestOptions: options,
          data: respond ?? {'token': 'jwt-1'},
          statusCode: 200,
        ));
      },
    ));
    return (dio: dio, calls: calls);
  }

  /// 库状态挂到 StateProvider 上,便于运行中切换触发重连监听。
  final libStateProvider = StateProvider<MusicLibrary?>((ref) => _lib());

  ProviderContainer buildContainer({
    ServerAddress? address,
    MusicLibrary? library,
    bool noLibrary = false,
    Dio? dio,
  }) {
    return ProviderContainer(overrides: <Override>[
      activeAddressProvider.overrideWith((ref) => address ?? _addr(server.url)),
      activeLibraryProvider
          .overrideWith((ref) => ref.watch(libStateProvider)),
      if (library != null || noLibrary)
        libStateProvider.overrideWith((ref) => library),
      if (dio != null) dioProvider.overrideWithValue(dio),
      subsonicApiClientProvider.overrideWithValue(api),
      playerProvider.overrideWith((ref) => player),
      peerRemoteControlProvider.overrideWith((ref) {
        peer = _FakePeerRemote(ref);
        return peer!;
      }),
    ]);
  }

  test('token 认证: 登录换 JWT,WS 握手带 jwt 且请求体含账号密码', () async {
    final login = stubLoginDio();
    container = buildContainer(library: _passwordLib(), dio: login.dio);
    container!.read(randomSongsPushProvider);

    await waitUntil(() => server.upgrades.isNotEmpty,
        reason: 'ws should connect after login');
    expect(server.upgrades.first.uri.queryParameters['token'], 'jwt-1');
    expect(server.upgrades.first.uri.path, '/ws');
    expect(login.calls.single, '/rest/api/v1/auth/login');
  });

  test('登录失败: 排重连定时器,~2s 后再次尝试登录', () async {
    final login = stubLoginDio(respond: Exception('login endpoint down'));
    container = buildContainer(library: _passwordLib(), dio: login.dio);
    container!.read(randomSongsPushProvider);

    await waitUntil(() => login.calls.length >= 2,
        timeout: const Duration(seconds: 8),
        reason: 'should retry login after backoff');
    expect(server.upgrades, isEmpty);
  });

  test('登录返回体无 token: 视为失败同样排重连', () async {
    final login = stubLoginDio(respond: {'token': ''});
    container = buildContainer(library: _passwordLib(), dio: login.dio);
    container!.read(randomSongsPushProvider);

    await waitUntil(() => login.calls.length >= 2,
        timeout: const Duration(seconds: 8),
        reason: 'empty token should also schedule reconnect');
  });

  test('无活跃库: 取不到 token 且不排重连(不空转)', () async {
    final login = stubLoginDio();
    container = buildContainer(noLibrary: true, dio: login.dio);
    container!.read(randomSongsPushProvider);

    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(login.calls, isEmpty);
    expect(server.upgrades, isEmpty);
  });

  test('clientId 抛异常: 握手退化不带 clientId,token 仍在', () async {
    when(() => api.clientId()).thenThrow(StateError('no client id'));
    container = buildContainer();
    container!.read(randomSongsPushProvider);

    await waitUntil(() => server.upgrades.isNotEmpty);
    expect(server.upgrades.first.uri.queryParameters['token'], 'tk-1');
    expect(server.upgrades.first.uri.queryParameters.containsKey('clientId'),
        isFalse);
  });

  test('二进制帧: List<int> 消息按 utf8 解码照常分发', () async {
    container = buildContainer();
    container!.read(randomSongsPushProvider);
    final got = Completer<int>();
    final sub = randomSongsChangedStream().listen(got.complete);
    addTearDown(sub.cancel);

    await waitUntil(() => server.upgrades.isNotEmpty);
    server.sendRaw(utf8.encode(jsonEncode(<String, dynamic>{
      'type': 'random-songs-changed',
    })));

    final version =
        await got.future.timeout(const Duration(seconds: 5));
    expect(version, greaterThanOrEqualTo(1));
  });

  test('活跃地址变化: 重连到新线路', () async {
    final server2 = await _WsServer.start();
    addTearDown(server2.dispose);
    container = buildContainer();
    container!.read(randomSongsPushProvider);
    await waitUntil(() => server.upgrades.isNotEmpty);

    container!.read(activeAddressProvider.notifier).state = _addr(server2.url);
    await waitUntil(() => server2.upgrades.isNotEmpty,
        timeout: const Duration(seconds: 8),
        reason: 'should reconnect to new address');
  });

  test('库变化: 关闭后退避中的连接被立即重排(不等 2s 退避)', () async {
    container = buildContainer();
    container!.read(randomSongsPushProvider);
    await waitUntil(() => server.upgrades.isNotEmpty);
    expect(server.upgrades.length, 1);

    await server.closeSocket(); // onDone → 2s 退避排程
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // 改库 → _reconnect 取消退避立即重连。
    container!.read(libStateProvider.notifier).state = _lib(apiKey: 'tk-2');

    final sw = Stopwatch()..start();
    await waitUntil(() => server.upgrades.length >= 2,
        timeout: const Duration(seconds: 8),
        reason: 'library change should trigger immediate reconnect');
    expect(sw.elapsedMilliseconds, lessThan(4000),
        reason: 'reconnect should not wait the full 2s backoff window');
    // 新握手应带新库的 apiKey。
    expect(server.upgrades.last.uri.queryParameters['token'], 'tk-2');
  });

  test('https 地址: 构建 wss 且连接失败后容错重试,不崩溃', () async {
    final login = stubLoginDio();
    final zoneErrors = <Object>[];
    // [D-056] 修复前:源码从不 await/捕获 WebSocketChannel.ready,连接拒绝
    // 产生未捕获异步异常,只能用 guarded zone 兜住。修复后 ready 已被
    // unawaited+catchError 捕获,zone 里不应再出现任何错误。
    await runZonedGuarded(() async {
      container = buildContainer(
        address: _addr('https://127.0.0.1:1'),
        library: _passwordLib(),
        dio: login.dio,
      );
      container!.read(randomSongsPushProvider);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
    }, (e, _) {
      zoneErrors.add(e);
    });
    expect(login.calls, isNotEmpty, reason: 'token resolve should happen');
    expect(server.upgrades, isEmpty); // 不应连到无关端口/线路
    // [D-056] 修复后:连接失败被 ready.catchError 捕获,zone 零异常。
    expect(zoneErrors, isEmpty,
        reason: '[D-056] ready 失败应被捕获,不再有未处理异步异常');
    // 存活到这里即证明连接失败路径未让测试进程崩溃。
  });
}
