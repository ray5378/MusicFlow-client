import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

import '../features/player/test_player_notifier.dart';

/// ============================================================================
/// 接续搬移 **端到端** 链路模拟（真 HTTP 服务端 + 真 ProviderContainer）
///
/// 为什么要有这一层：`cast_peer_provider_test.dart` 里的 mocktail 单测只断言
/// 「发了什么请求」，无法回答「真实 HTTP 语义下这条链路能不能跑通」——
/// 比如响应的 JSON 形状、鉴权、超时、以及**服务端是否真的解析出了队列**。
///
/// 本测试起一个**本地 HTTP 假服务端**（模拟真实 MusicFlow 服务端的关键端点），
/// 然后让真实的 CastPeerController 走完整的 `pushLocalToPeer` 流程，验证：
///   1. 主通道优先：请求命中 `/rest/api/v1/play`，且 body 里**没有**整队 items；
///   2. 服务端按 {type,id} 自行解析出队列并投递给设备（模拟设备收到 SetAVTransportURI）；
///   3. 大歌单（3251 首，真实故障规模）下 body 仍只有百来字节；
///   4. 来源不可解析（discover）时确实回落整队推送，且设备仍收到内容。
///
/// 这条测试的价值：它是**唯一**能把「客户端改法」与「服务端契约」串起来验证
/// 的地方，mocktail 层做不到（它不解析真实 HTTP body）。
/// ============================================================================

/// 极简 MusicFlow 服务端模拟：实现搬移链路用到的三个端点。
class _FakeMusicFlowServer {
  _FakeMusicFlowServer(this._queueOf);

  /// 内容 id → 歌曲 id 列表（模拟服务端 resolveContentSongs）。
  final List<String> Function(String type, String id) _queueOf;

  HttpServer? _server;
  int get port => _server!.port;
  String get baseUrl => 'http://127.0.0.1:$port';

  /// 记录服务端收到的请求，供断言。
  final List<String> mainChannelHits = <String>[];
  final List<String> queuePlayHits = <String>[];

  /// 模拟设备侧实际被投递的 URI（服务端推流的产物）。
  final List<String> deliveredUris = <String>[];

  /// 主通道是否返回失败（测试回落用）。
  bool mainChannelFails = false;

  /// 主通道是否返回 404（模拟内容已删）。
  bool mainChannelNotFound = false;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> close() => _server?.close(force: true) ?? Future<void>.value();

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final body = await utf8.decoder.bind(req).join();
    final res = req.response;
    // 必须是 JSON content-type：真实服务端如此，且客户端 getRaw/postRaw 只在
    // content-type 为 JSON 时把 body 解析成 Map，否则返回 String，
    // 会让 `resp is! Map` 判定为失败（曾导致本测试 4/5 假红）。
    res.headers.contentType = ContentType.json;

    if (path == '/rest/api/v1/play') {
      mainChannelHits.add(body);
      final map = body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(body) as Map<String, dynamic>;
      if (mainChannelNotFound) {
        res.statusCode = 404;
        res.write(jsonEncode(<String, dynamic>{'success': false}));
        await res.close();
        return;
      }
      if (mainChannelFails) {
        res.write(jsonEncode(<String, dynamic>{'success': false}));
        await res.close();
        return;
      }
      final type = '${map['type']}';
      final id = '${map['id']}';
      final songId = map['songId']?.toString();
      final ids = _queueOf(type, id);
      if (ids.isEmpty) {
        res.statusCode = 404;
        res.write(jsonEncode(<String, dynamic>{'success': false}));
        await res.close();
        return;
      }
      // 服务端按 songId 身份定位起点（与排序无关），模拟真实语义。
      var idx = songId == null ? 0 : ids.indexOf(songId);
      if (idx < 0) idx = 0;
      // 服务端自行投流到设备：这里用「记录被投递的 URI」表示。
      deliveredUris.add('${baseUrl}/rest/dlna/stream/${ids[idx]}');
      res.write(jsonEncode(<String, dynamic>{
        'success': true,
        'resolved': ids.length,
        'startIndex': idx,
      }));
      await res.close();
      return;
    }

    if (path.startsWith('/rest/api/v1/peers/') && path.endsWith('/queue/play')) {
      queuePlayHits.add(body);
      final map = jsonDecode(body) as Map<String, dynamic>;
      final items = (map['items'] as List?) ?? const [];
      final start = (map['startIndex'] as num?)?.toInt() ?? 0;
      if (items.isNotEmpty) {
        final it = items[start.clamp(0, items.length - 1)] as Map;
        deliveredUris.add('${baseUrl}/rest/dlna/stream/${it['songId']}');
      }
      res.write(jsonEncode(<String, dynamic>{'success': true}));
      await res.close();
      return;
    }

    if (path.endsWith('/play-mode')) {
      res.write(jsonEncode(<String, dynamic>{}));
      await res.close();
      return;
    }

    // 状态轮询：返回可解析的 PeerStatus（缺字段会让解析抛错，掩盖真实失败）。
    if (path.endsWith('/status')) {
      res.write(jsonEncode(<String, dynamic>{
        'state': 'PLAYING',
        'active': true,
        'position': 0,
        'duration': 0,
      }));
      await res.close();
      return;
    }

    // 轮询用队列快照：返回空队列即可（本测试只验起播通道）。
    if (path.startsWith('/rest/api/v1/peers/') && path.endsWith('/queue')) {
      res.write(jsonEncode(<String, dynamic>{
        'currentIndex': 0,
        'total': 0,
        'playMode': 'all',
        'items': <dynamic>[],
        'shuffleOrder': <int>[],
        'shufflePos': -1,
      }));
      await res.close();
      return;
    }

    res.statusCode = 404;
    await res.close();
  }
}

void main() {
  late _FakeMusicFlowServer server;
  late TestPlayerNotifier playerNotifier;
  late ProviderContainer container;
  late CastPeerController controller;

  const dlnaPeer = PeerInfo(
    peerId: 'dlna-e2e',
    name: '客厅音箱',
    kind: 'dlna',
    available: true,
  );

  /// 造一个真实规模的歌单（3251 首 = 线上真实故障规模）。
  List<String> bigPlaylist() =>
      <String>[for (var i = 0; i < 3251; i++) 'song-$i'];

  setUp(() async {
    server = _FakeMusicFlowServer((type, id) {
      if (type == 'playlist' && id == 'pl-e2e') return bigPlaylist();
      return const <String>[];
    });
    await server.start();

    final client = SubsonicApiClient(
      dio: Dio(
        BaseOptions(
          baseUrl: server.baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 60),
          sendTimeout: const Duration(seconds: 60),
        ),
      ),
    );
    playerNotifier = TestPlayerNotifier(PlayerState());
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        playerProvider.overrideWith((ref) => playerNotifier),
      ],
    );
    controller = container.read(castPeerControllerProvider.notifier);
    // 开启日志缓冲：断言失败时能打印被 catch 掉的真实原因（见下方 PUSH-FALSE）。
    Logger.setLoggingEnabled(true);
    Logger.clearBuffer();
  });

  tearDown(() async {
    container.dispose();
    await server.close();
    Logger.setLoggingEnabled(false);
    Logger.clearBuffer();
  });

  List<Song> songs(List<String> ids) =>
      <Song>[for (final id in ids) Song(id: id, title: id, duration: 200)];

  test('E2E 大歌单搬移：主通道优先，body 不含整队，服务端自行解析并投流', () async {
    final ids = bigPlaylist();
    playerNotifier.emit(
      PlayerState(
        currentSong: Song(id: ids[0], title: ids[0]),
        queue: songs(ids),
        currentIndex: 0,
        loopMode: LoopMode.all,
      ),
    );
    container.read(queueOriginProvider.notifier).state =
        const QueueOrigin(QueueOriginKind.playlist, 'pl-e2e');

    // 真实 HTTP 调用（非 mock）。
    final ok = await controller.pushLocalToPeer(dlnaPeer);
    if (!ok) {
      debugPrint('PUSH-FALSE LOGS: ${Logger.exportLogs()}');
    }
    expect(ok, isTrue, reason: '主通道应起播成功');

    // 1) 命中主通道，且只发了一次
    expect(server.mainChannelHits, hasLength(1));
    // 2) 整队推送**从未**被调用（这是本修复的核心）
    expect(server.queuePlayHits, isEmpty,
        reason: '3251 首绝不该走整队推送（MB 级 body）');

    // 3) body 极小且只含 {peerId,type,id,songId}
    final body = server.mainChannelHits.single;
    expect(body.length, lessThan(400), reason: '主通道 body 必须只有几百字节');
    expect(body.contains('"items"'), isFalse);
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    expect(decoded['type'], 'playlist');
    expect(decoded['id'], 'pl-e2e');
    expect(decoded['songId'], ids[0]);

    // 4) 服务端解析出完整 3251 首并按身份定位到第 0 首，投流给设备
    expect(server.deliveredUris, hasLength(1));
    expect(server.deliveredUris.single, contains(ids[0]));
  });

  test('E2E 起点按身份定位：本机第 500 首 → 服务端投递的也是同一首', () async {
    final ids = bigPlaylist();
    const pick = 500;
    playerNotifier.emit(
      PlayerState(
        currentSong: Song(id: ids[pick], title: ids[pick]),
        queue: songs(ids),
        currentIndex: pick,
        loopMode: LoopMode.all,
      ),
    );
    container.read(queueOriginProvider.notifier).state =
        const QueueOrigin(QueueOriginKind.playlist, 'pl-e2e');

    final ok = await controller.pushLocalToPeer(dlnaPeer);
    expect(ok, isTrue);

    // 关键：投递的必须是本机那一首（身份对齐），不是服务端队列的第 500 个槽位。
    expect(server.deliveredUris.single, contains(ids[pick]));
  });

  test('E2E 来源不可解析（discover）：回落整队推送，设备仍拿到内容', () async {
    final ids = <String>['a1', 'a2', 'a3'];
    playerNotifier.emit(
      PlayerState(
        currentSong: Song(id: 'a1', title: 'a1'),
        queue: songs(ids),
        currentIndex: 0,
        loopMode: LoopMode.all,
      ),
    );
    container.read(queueOriginProvider.notifier).state =
        const QueueOrigin(QueueOriginKind.discover);

    final ok = await controller.pushLocalToPeer(dlnaPeer);
    expect(ok, isTrue, reason: '兜底通道应保证搬移仍成功');

    // discover 服务端无从解析 → 必须走整队推送，且不得碰主通道。
    expect(server.mainChannelHits, isEmpty);
    expect(server.queuePlayHits, hasLength(1));
    expect(server.deliveredUris.single, contains('a1'));
  });

  test('E2E 内容已删（主通道 404）：自动回落整队推送，搬移不失败', () async {
    server.mainChannelNotFound = true;
    final ids = <String>['b1', 'b2'];
    playerNotifier.emit(
      PlayerState(
        currentSong: Song(id: 'b1', title: 'b1'),
        queue: songs(ids),
        currentIndex: 0,
        loopMode: LoopMode.all,
      ),
    );
    container.read(queueOriginProvider.notifier).state =
        const QueueOrigin(QueueOriginKind.playlist, 'pl-e2e');

    final ok = await controller.pushLocalToPeer(dlnaPeer);

    expect(ok, isTrue, reason: '主通道失败后兜底成功，用户不应看到失败');
    expect(server.mainChannelHits, hasLength(1));
    expect(server.queuePlayHits, hasLength(1));
    expect(server.deliveredUris, hasLength(1));
  });

  test('E2E 空队列：不发任何请求，直接返回 false', () async {
    playerNotifier.emit(PlayerState());
    final ok = await controller.pushLocalToPeer(dlnaPeer);
    expect(ok, isFalse);
    expect(server.mainChannelHits, isEmpty);
    expect(server.queuePlayHits, isEmpty);
  });
}
