import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/cast/peer_remote_control_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/library/random_songs_push_provider.dart';

import '../../helpers/mocks.dart';
import '../../features/player/test_player_notifier.dart';

/// b33b: random_songs_push_provider.dart 补测。
/// 用本地 HttpServer + WebSocketTransformer 起真实 WS 服务,
/// 覆盖: 握手参数(token/clientId)、random-songs-changed 广播、
/// song_starred 镜像(含空 id 跳过)、peer_command 转交、非 JSON 容错、
/// 断线自动重连、无地址时排重连定时器、dispose 幂等清理。

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

  void send(Map<String, dynamic> msg) => _socket!.add(jsonEncode(msg));

  void sendRaw(String raw) => _socket!.add(raw);

  Future<void> closeSocket() => _socket!.close();

  Future<void> dispose() => server.close(force: true);
}

MusicLibrary _lib() => MusicLibrary(
      id: 'lib-1',
      name: 'Test',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
      authType: MusicLibraryAuthType.apiKey,
      apiKey: 'tk-1',
    );

ServerAddress _addr(String url) => ServerAddress(
      id: 'a1',
      libraryId: 'lib-1',
      label: 'Home',
      url: url,
      priority: 0,
    );

class _FakePeerRemote extends PeerRemoteControlNotifier {
  _FakePeerRemote(super.ref);

  final List<Map<String, dynamic>> handled = <Map<String, dynamic>>[];

  @override
  Future<void> handleServerMessage(Map<String, dynamic> msg) async {
    handled.add(msg);
  }
}

class _RecordingPlayer extends TestPlayerNotifier {
  _RecordingPlayer() : super(PlayerState());

  final List<MapEntry<String, bool>> starredCalls =
      <MapEntry<String, bool>>[];

  @override
  void applyExternalStarred(String songId, bool starred) {
    starredCalls.add(MapEntry(songId, starred));
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

  /// 构建容器;读 push provider 前 peer 通过 override 工厂注入。
  ProviderContainer buildContainer({ServerAddress? address}) {
    return ProviderContainer(overrides: <Override>[
      activeAddressProvider.overrideWith((ref) => address ?? _addr(server.url)),
      activeLibraryProvider.overrideWithValue(_lib()),
      subsonicApiClientProvider.overrideWithValue(api),
      playerProvider.overrideWith((ref) => player),
      peerRemoteControlProvider.overrideWith((ref) {
        peer = _FakePeerRemote(ref);
        return peer!;
      }),
    ]);
  }

  void startClient({ServerAddress? address}) {
    container = buildContainer(address: address);
    container!.read(randomSongsPushProvider);
  }

  test('握手: WS 请求带 token 与 clientId,path 为 /ws', () async {
    startClient();
    await waitUntil(() => server.upgrades.isNotEmpty,
        reason: 'client should connect to local ws server');
    final uri = server.upgrades.first.uri;
    expect(uri.path, '/ws');
    expect(uri.queryParameters['token'], 'tk-1');
    expect(uri.queryParameters['clientId'], 'cid-1');
  });

  test('random-songs-changed → notifyRandomSongsChanged 广播版本号', () async {
    startClient();
    final got = Completer<int>();
    final sub = randomSongsChangedStream().listen(got.complete);
    addTearDown(sub.cancel);

    await waitUntil(() => server.upgrades.isNotEmpty);
    server.send(<String, dynamic>{'type': 'random-songs-changed'});

    final version = await got.future.timeout(const Duration(seconds: 5));
    expect(version, greaterThanOrEqualTo(1));
  });

  test('song_starred: 应用非空 id、跳过空 id、false 也能传递', () async {
    startClient();
    await waitUntil(() => server.upgrades.isNotEmpty);

    server.send(<String, dynamic>{
      'type': 'song_starred',
      'songIds': <String>['s1', ''],
      'starred': true,
    });
    await waitUntil(() => player.starredCalls.isNotEmpty,
        reason: 'starred s1 should be applied');
    expect(player.starredCalls.first.key, 's1');
    expect(player.starredCalls.first.value, isTrue);

    server.send(<String, dynamic>{
      'type': 'song_starred',
      'songIds': <String>['s2'],
      'starred': false,
    });
    await waitUntil(() => player.starredCalls.length >= 2);
    expect(player.starredCalls[1].key, 's2');
    expect(player.starredCalls[1].value, isFalse);
  });

  test('peer_command → 转交 peerRemoteControlProvider 处理', () async {
    startClient();
    await waitUntil(() => server.upgrades.isNotEmpty);

    server.send(<String, dynamic>{
      'type': 'peer_command',
      'action': 'pause',
    });
    await waitUntil(() => (peer?.handled.isNotEmpty ?? false),
        reason: 'peer_command should be forwarded');
    expect(peer!.handled.first['action'], 'pause');
  });

  test('未知类型/非 JSON/非 Map 消息被忽略,不崩溃', () async {
    startClient();
    // 强制实例化本测试的 peer 桩(否则惰性工厂不执行,peer 仍是上一用例的实例)。
    container!.read(peerRemoteControlProvider.notifier);
    await waitUntil(() => server.upgrades.isNotEmpty);

    server.send(<String, dynamic>{'type': 'totally-unknown'});
    server.sendRaw('not-json-at-all');
    server.sendRaw('[1,2,3]');

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(peer?.handled ?? <Map<String, dynamic>>[], isEmpty);
    expect(player.starredCalls, isEmpty);
  });

  test('服务器断开 → 自动重连(退避从 2s 起)', () async {
    startClient();
    await waitUntil(() => server.upgrades.isNotEmpty);
    expect(server.upgrades.length, 1);

    await server.closeSocket();
    // onDone → _scheduleReconnect(2s) → 第二次连接。
    await waitUntil(() => server.upgrades.length >= 2,
        timeout: const Duration(seconds: 10),
        reason: 'client should reconnect after server closes');
  });

  test('无活跃地址: 排重连定时器待命,不产生连接', () async {
    container = ProviderContainer(overrides: <Override>[
      activeAddressProvider.overrideWith((ref) => null),
      activeLibraryProvider.overrideWithValue(_lib()),
      subsonicApiClientProvider.overrideWithValue(api),
      playerProvider.overrideWith((ref) => player),
      peerRemoteControlProvider.overrideWith((ref) {
        peer = _FakePeerRemote(ref);
        return peer!;
      }),
    ]);
    container!.read(randomSongsPushProvider);
    // _connect 无地址 → _scheduleReconnect;等一段确认不崩、不连。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(server.upgrades, isEmpty);
  });

  test('dispose 幂等: 重复调用不抛异常', () async {
    startClient();
    final client = container!.read(randomSongsPushProvider);

    await waitUntil(() => server.upgrades.isNotEmpty);
    container!.dispose();
    // container.dispose 已触发 ref.onDispose(client.dispose);再手动调用应安全。
    client.dispose();
    client.dispose();
  });
}
