// 退出时播放状态落盘守卫(2026-09-12)。
//
// 锁死「客户端退出/被强杀时把播放会话写入配置、下次启动能读回」这条链路——
// 此前只有 Payload 编码器(队列/进度/索引/模式/来源 形状)由 playback_payload_test
// 在阻塞式 offline-cache-guard 覆盖,而**真正的落盘 I/O**(LocalStorage 经
// JsonFileStore 的 tmp+rename 原子写 + 读回 + 损坏/缺失健壮降级)没有任何测试。
// 这一层一旦回归,「退出后音量回到 100% / 重启不续播 / 直接崩溃」之类问题只
// 有真人在桌面端能发现。
//
// 关键断言(钉死静默失效):
//   A. save → get 往返保真(队列/索引/进度/模式/来源逐字段相等,不丢不歪);
//   B. clear 后读回 null;
//   C. 缺失文件 / 损坏 JSON 读回 null 且不抛(启动健壮降级,绝不卡死恢复流程)。
//   D. 音量独立成块落盘:set/get 往返保真 —— 复现「退出后音量不回弹」防线。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';

void main() {
  // 本测试共用 JsonFileStore 单例,用独立临时目录隔离,避免与其它测试同键串扰。
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mf_session_persist_');
    JsonFileStore.instance.debugDirectory = dir;
  });

  tearDown(() {
    JsonFileStore.instance.debugDirectory = null;
  });

  Map<String, dynamic> _sampleSession({
    List<Map<String, dynamic>> queue = const [
      {'id': 'a', 'title': 'A'},
      {'id': 'b', 'title': 'B'},
      {'id': 'c', 'title': 'C'},
    ],
    int currentIndex = 1,
    String currentSongId = 'b',
    int positionMs = 42300,
    bool isPlaying = true,
    int? updatedAt = 1700000000000,
    Map<String, dynamic>? queueOrigin,
  }) =>
      <String, dynamic>{
        'version': 1,
        'queue': queue,
        'currentIndex': currentIndex,
        'currentSongId': currentSongId,
        'positionMs': positionMs,
        'isPlaying': isPlaying,
        'updatedAt': updatedAt,
        if (queueOrigin != null) 'queueOrigin': queueOrigin,
      };

  group('A. 落盘往返保真(save → get)', () {
    test('含来源的完整会话逐字段往返相等', () async {
      final payload = _sampleSession(
        queueOrigin: const {
          'kind': 'playlist',
          'id': 'pl-42',
          'serverContentType': 'playlist',
        },
      );

      await LocalStorage.savePlaybackSession(payload);
      final read = await LocalStorage.getPlaybackSession();

      expect(read, isNotNull);
      expect(read!['queue'], payload['queue']);
      expect(read['currentIndex'], 1);
      expect(read['currentSongId'], 'b');
      expect(read['positionMs'], 42300);
      expect(read['isPlaying'], isTrue);
      expect(read['updatedAt'], 1700000000000);
      expect(read['queueOrigin']['kind'], 'playlist');
      expect(read['queueOrigin']['id'], 'pl-42');
    });

    test('空队列会话也能往返(只保留进度/模式,无歌曲)', () async {
      final payload = _sampleSession(
        queue: const [],
        currentIndex: 0,
        currentSongId: '',
        positionMs: 0,
        isPlaying: false,
      );
      await LocalStorage.savePlaybackSession(payload);
      final read = await LocalStorage.getPlaybackSession();
      expect(read, isNotNull);
      expect(read!['queue'], isEmpty);
      expect(read['isPlaying'], isFalse);
    });

    test('多次覆盖写入读回最后一次(强杀前最后一次进度为准)', () async {
      await LocalStorage.savePlaybackSession(_sampleSession(positionMs: 1000));
      await LocalStorage.savePlaybackSession(_sampleSession(positionMs: 99999));
      final read = await LocalStorage.getPlaybackSession();
      expect(read!['positionMs'], 99999);
    });
  });

  group('B. clear 与缺失/损坏健壮降级', () {
    test('clear 后读回 null', () async {
      await LocalStorage.savePlaybackSession(_sampleSession());
      await LocalStorage.clearPlaybackSession();
      expect(await LocalStorage.getPlaybackSession(), isNull);
    });

    test('从未写入时读回 null 且不抛(启动无旧会话)', () async {
      expect(await LocalStorage.getPlaybackSession(), isNull);
    });

    test('损坏 JSON 读回 null 且不抛(启动健壮降级,绝不卡死恢复)', () async {
      final file = File(
        '${dir.path}${Platform.pathSeparator}playback_session_v1.json',
      );
      await file.writeAsString('this is not json {{{');
      final result = await LocalStorage.getPlaybackSession();
      expect(result, isNull);
    });

    test('非 map 负载(裸数组)读回 null 且不抛', () async {
      final file = File(
        '${dir.path}${Platform.pathSeparator}playback_session_v1.json',
      );
      await file.writeAsString(jsonEncode([1, 2, 3]));
      expect(await LocalStorage.getPlaybackSession(), isNull);
    });
  });

  group('C. 音量独立落盘(退出后不回弹防线)', () {
    test('setPlayerVolume → getPlayerVolume 往返保真', () async {
      await LocalStorage.setPlayerVolume(0.37);
      expect(await LocalStorage.getPlayerVolume(), closeTo(0.37, 1e-9));
      await LocalStorage.setPlayerVolume(1.0);
      expect(await LocalStorage.getPlayerVolume(), 1.0);
    });

    test('缺失时回落 0.8(默认音量,不卡读取)', () async {
      expect(await LocalStorage.getPlayerVolume(), 0.8);
    });
  });
}
