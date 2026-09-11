import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

/// 服务端契约测试(client 视角,对应主仓 backend/tests/routes/clientContract.test.ts)。
///
/// 与服务端 v2.3.28「播放端临时 ID 隔离」联动。锁定的契约 —— 任何一侧改动
/// 必须同步另一侧,否则跨仓发版会破:
///   1. QueueItem 序列化:必须带 `mime`(服务端 QueueItem 只持久化 mime,
///      不存 suffix);客户端逆向还原 suffix 靠 mime 反查 —— 所以这里**禁止
///      出现 suffix 键**,且 mime 映射必须与后端 MIME_SUFFIX 表一致。
///   2. register 响应解析:`{peer: {peerId}}`,peerId 恒为 `local:<userId>`
///      (临时端 ID 不出服务端);响应畸形/网络异常不 crash、不阻塞登录。
///   3. 本机队列上报:队列变 → `queue/play` {items, startIndex} + 补发
///      `play-mode`;游标变 → `queue/index` {index};空队列且从未上报过
///      内容 → 不发请求(防启动空窗擦掉服务端队列)。
///   4. 播放模式映射值域:order/one/all/shuffle 全部在服务端 PlayMode 枚举内。
void main() {
  late MockSubsonicApiClient client;
  late TestPlayerNotifier playerNotifier;
  late ProviderContainer container;
  late CastPeerController controller;

  Song song(String id, {String? suffix}) => Song(
        id: id,
        title: 't-$id',
        artist: 'a',
        albumId: 'al1',
        suffix: suffix,
        duration: 120,
      );

  setUp(() {
    client = MockSubsonicApiClient();
    playerNotifier = TestPlayerNotifier(PlayerState());
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        playerProvider.overrideWith((ref) => playerNotifier),
      ],
    );
    controller = container.read(castPeerControllerProvider.notifier);
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(const Duration(seconds: 10));
  });

  tearDown(() {
    controller.stopHeartbeat();
    container.dispose();
  });

  group('契约1: QueueItem 序列化(与后端 MIME_SUFFIX 表对齐)', () {
    test('含 mime 与 songId,禁止出现 suffix 键', () {
      final item = songToQueueItem(song('s1', suffix: 'flac'));
      expect(item['mime'], 'audio/flac');
      expect(item.containsKey('suffix'), isFalse,
          reason: '服务端 QueueItem 只存 mime;多带 suffix 会让契约漂移');
      expect(item['songId'], 's1');
    });

    test('全格式 mime 映射与后端一致,未知后缀回落 audio/mpeg', () {
      const cases = <String, String>{
        'mp3': 'audio/mpeg',
        'flac': 'audio/flac',
        'wav': 'audio/wav',
        'aac': 'audio/aac',
        'ogg': 'audio/ogg',
        'm4a': 'audio/mp4',
        'opus': 'audio/opus',
        'wma': 'audio/x-ms-wma',
        'ape': 'audio/ape',
      };
      cases.forEach((suffix, mime) {
        expect(songToQueueItem(song('x', suffix: suffix))['mime'], mime,
            reason: 'suffix=$suffix');
      });
      expect(songToQueueItem(song('x'))['mime'], 'audio/mpeg');
    });
  });

  group('契约2: register 响应解析(临时 ID 打码)', () {
    test('成功:解析 local:<uid> 并以该 id 发心跳', () async {
      when(() => client.postRaw('/rest/api/v1/peers/register',
              data: any(named: 'data')))
          .thenAnswer((_) async => <String, dynamic>{
                'peer': <String, dynamic>{
                  'peerId': 'local:user-1',
                  'kind': 'local',
                  'available': true,
                },
              });
      when(() => client.postRaw(
              '/rest/api/v1/peers/local%3Auser-1/heartbeat'))
          .thenAnswer((_) async => <String, dynamic>{});
      await controller.registerAndHeartbeat();
      verify(() => client.postRaw(
              '/rest/api/v1/peers/local%3Auser-1/heartbeat'))
          .called(1);
    });

    test('响应畸形(缺 peer/缺 peerId)不 crash,不发心跳', () async {
      when(() => client.postRaw('/rest/api/v1/peers/register',
              data: any(named: 'data')))
          .thenAnswer((_) async => <String, dynamic>{'peer': 'garbage'});
      await controller.registerAndHeartbeat();
      verifyNever(() => client.postRaw(any()));
    });

    test('网络异常不 crash(下个心跳周期自动补注册)', () async {
      when(() => client.postRaw('/rest/api/v1/peers/register',
              data: any(named: 'data'))).thenThrow(Exception('boom'));
      await controller.registerAndHeartbeat();
      // 未拿到 peerId → 心跳不发;异常被吞,无未捕获错误。
      verifyNever(() => client.postRaw(any()));
    });
  });

  group('契约3: 本机队列上报载荷', () {
    Future<void> pumpSync() async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await Future<void>.delayed(Duration.zero);
    }

    /// 统一 stub:mocktail 对同一方法的多次 when 会互相覆盖,必须一个
    /// stub 内按 path 分支,否则 register 会被宽 matcher stub 顶掉。
    void stubPostRaw(String pid) {
      when(() => client.postRaw(any(),
              data: any(named: 'data'),
              receiveTimeout: any(named: 'receiveTimeout')))
          .thenAnswer((Invocation inv) async {
        final path = inv.positionalArguments.first as String;
        if (path.endsWith('/register')) {
          return <String, dynamic>{
            'peer': <String, dynamic>{'peerId': pid, 'kind': 'local'},
          };
        }
        return <String, dynamic>{};
      });
    }

    test('队列变化 → queue/play{items,startIndex} + play-mode 补发', () async {
      const pid = 'local:user-1';
      stubPostRaw(pid);
      final pidEnc = Uri.encodeComponent(pid); // verify 路径用编码后的形式

      await controller.registerAndHeartbeat();
      playerNotifier.emit(PlayerState(
        queue: <Song>[song('s1', suffix: 'flac'), song('s2')],
        currentIndex: 1,
      ));
      await pumpSync();

      final captured = verify(() => client.postRaw(
              '/rest/api/v1/peers/$pidEnc/queue/play',
              data: captureAny(named: 'data'),
              receiveTimeout: any(named: 'receiveTimeout')))
          .captured;
      final body = captured.last as Map<String, dynamic>;
      expect(body['startIndex'], 1);
      final items = body['items'] as List<dynamic>;
      expect((items[0] as Map<String, dynamic>)['mime'], 'audio/flac');
      expect((items[0] as Map<String, dynamic>).containsKey('suffix'), isFalse);
      // queue/play 后必须补发当前模式(服务端会把它重置为 order)
      verify(() => client.postRaw('/rest/api/v1/peers/$pidEnc/play-mode',
              data: any(named: 'data'))).called(1);
    });

    test('仅游标变化 → 只发 queue/index{index},不整队重推', () async {
      const pid = 'local:user-1';
      stubPostRaw(pid);
      final pidEnc = Uri.encodeComponent(pid); // verify 路径用编码后的形式

      await controller.registerAndHeartbeat();
      final queue = <Song>[song('s1'), song('s2')];
      playerNotifier.emit(PlayerState(queue: queue, currentIndex: 0));
      await pumpSync();
      clearInteractions(client);

      playerNotifier.emit(PlayerState(queue: queue, currentIndex: 1));
      await pumpSync();

      verify(() => client.postRaw('/rest/api/v1/peers/$pidEnc/queue/index',
              data: any(named: 'data'))).called(1);
      verifyNever(() => client.postRaw('/rest/api/v1/peers/$pidEnc/queue/play',
          data: any(named: 'data'), receiveTimeout: any(named: 'receiveTimeout')));
    });

    test('启动空窗:空队列且从未上报过 → 不发任何擦除请求', () async {
      stubPostRaw('local:u');
      await controller.registerAndHeartbeat();
      clearInteractions(client);
      playerNotifier.emit(PlayerState(queue: const <Song>[], currentIndex: -1));
      await pumpSync();
      verifyNever(() => client.postRaw(any(),
          data: any(named: 'data'), receiveTimeout: any(named: 'receiveTimeout')));
      verifyNever(() => client.postRaw(any(), data: any(named: 'data')));
    });
  });

  group('契约4: 播放模式映射值域', () {
    test('order/one/all/shuffle 全部为服务端 PlayMode 枚举', () {
      expect(mapLocalPlayMode(PlaybackMode.order), 'order');
      expect(mapLocalPlayMode(PlaybackMode.one), 'one');
      expect(mapLocalPlayMode(PlaybackMode.all), 'all');
      expect(mapLocalPlayMode(PlaybackMode.shuffle), 'shuffle');
    });
  });
}
