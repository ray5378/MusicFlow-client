import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/player/playback_payload.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

Song _song(String id) => Song(id: id, title: id);

void main() {
  group('normalizeSeekPosition', () {
    test('负进度归零', () {
      expect(
        normalizeSeekPosition(const Duration(milliseconds: -5),
            const Duration(seconds: 60)),
        Duration.zero,
      );
    });

    test('超过时长裁到时长', () {
      expect(
        normalizeSeekPosition(const Duration(seconds: 90),
            const Duration(seconds: 60)),
        const Duration(seconds: 60),
      );
    });

    test('时长未知(duration=0)时不上限裁剪', () {
      expect(
        normalizeSeekPosition(const Duration(seconds: 500), Duration.zero),
        const Duration(seconds: 500),
      );
    });

    test('正常范围内保持不变', () {
      expect(
        normalizeSeekPosition(const Duration(seconds: 30),
            const Duration(seconds: 60)),
        const Duration(seconds: 30),
      );
    });
  });

  group('PlaybackPayloadEncoder.buildQueue', () {
    test('队列未变时复用同一序列化结果(对象 identical)', () {
      final e = PlaybackPayloadEncoder();
      final queue = [_song('a'), _song('b')];
      final first = e.buildQueue(queue);
      final second = e.buildQueue(queue);
      expect(identical(first, second), isTrue);
    });

    test('队列歌曲 id 变化时重建', () {
      final e = PlaybackPayloadEncoder();
      final first = e.buildQueue([_song('a'), _song('b')]);
      final second = e.buildQueue([_song('a'), _song('c')]);
      expect(identical(first, second), isFalse);
    });
  });

  group('PlaybackPayloadEncoder.buildSession', () {
    test('空队列返回 null', () {
      final e = PlaybackPayloadEncoder();
      expect(
        e.buildSession(
          queue: [],
          currentIndex: 0,
          currentSongId: null,
          position: Duration.zero,
          duration: Duration.zero,
          isPlaying: true,
          nowMs: 1,
        ),
        isNull,
      );
    });

    test('当前索引失配时按当前曲 id 重定位', () {
      final e = PlaybackPayloadEncoder();
      final queue = [_song('a'), _song('b'), _song('c')];
      // currentIndex=0 但 currentSongId=b → 应定位到索引 1。
      final p = e.buildSession(
        queue: queue,
        currentIndex: 0,
        currentSongId: 'b',
        position: const Duration(seconds: 5),
        duration: const Duration(seconds: 60),
        isPlaying: false,
        nowMs: 123,
      )!;
      expect(p['currentIndex'], 1);
      expect(p['currentSongId'], 'b');
    });

    test('无法定位当前曲返回 null', () {
      final e = PlaybackPayloadEncoder();
      final p = e.buildSession(
        queue: [_song('a')],
        currentIndex: 5, // 越界
        currentSongId: 'zzz',
        position: Duration.zero,
        duration: Duration.zero,
        isPlaying: true,
        nowMs: 1,
      );
      expect(p, isNull);
    });

    test('payload 字段完整且位置被归一化', () {
      final e = PlaybackPayloadEncoder();
      final queue = [_song('a')];
      final p = e.buildSession(
        queue: queue,
        currentIndex: 0,
        currentSongId: 'a',
        position: const Duration(seconds: 999),
        duration: const Duration(seconds: 10),
        isPlaying: true,
        nowMs: 42,
      )!;
      expect(p['version'], 1);
      expect(p['queue'], isList);
      expect(p['currentIndex'], 0);
      expect(p['currentSongId'], 'a');
      expect(p['positionMs'], 10000); // 裁到 duration
      expect(p['isPlaying'], isTrue);
      expect(p['updatedAt'], 42);
    });
  });

  // -------------------------------------------------------------------------
  // 队列来源随会话持久化（2026-09-10 修复）
  //
  // 根因：重启 App 后队列由 playback_session_v1 恢复，但恢复路径直接调
  // playerNotifier.playSong 而非 playEffectiveQueue（唯一来源写入点），
  // 若不落盘则 origin 丢失 → pushLocalToPeer 拿不到 serverContentType
  // → 本机→设备搬移被迫整队推送（数千首 ≈ MB 级，上行耗时随规模线性劣化）。
  // 这组测试锁死「写进去 → 读出来」这条往返链，防止再次静默丢失。
  // -------------------------------------------------------------------------
  group('队列来源持久化（buildSession queueOrigin）', () {
    Map<String, dynamic> build({Map<String, dynamic>? origin}) {
      final e = PlaybackPayloadEncoder();
      return e.buildSession(
        queue: [_song('a'), _song('b')],
        currentIndex: 1,
        currentSongId: 'b',
        position: Duration.zero,
        duration: const Duration(seconds: 60),
        isPlaying: true,
        nowMs: 1,
        queueOrigin: origin,
      )!;
    }

    test('传入来源时写入 queueOrigin 字段', () {
      final p = build(origin: const QueueOrigin(QueueOriginKind.playlist, 'pl-1').toJson());
      expect(p['queueOrigin'], isA<Map>());
      expect((p['queueOrigin'] as Map)['kind'], 'playlist');
      expect((p['queueOrigin'] as Map)['id'], 'pl-1');
    });

    test('未传来源时不出现 queueOrigin 键（旧格式兼容，不写空值）', () {
      expect(build().containsKey('queueOrigin'), isFalse);
    });

    test('歌单/专辑/艺术家来源往返后 serverContentType 保持可用', () {
      for (final (kind, type) in <(QueueOriginKind, String)>[
        (QueueOriginKind.playlist, 'playlist'),
        (QueueOriginKind.album, 'album'),
        (QueueOriginKind.artist, 'artist'),
      ]) {
        final p = build(origin: QueueOrigin(kind, 'x-1').toJson());
        final restored = QueueOrigin.fromJson(p['queueOrigin']);
        expect(restored, isNotNull, reason: '$kind 往返失败');
        expect(restored!.kind, kind);
        expect(restored.id, 'x-1');
        // 核心契约：往返后仍能走主通道。
        expect(restored.serverContentType, type);
      }
    });

    test('本地拼装来源（discover/search/other）往返后不误走主通道', () {
      for (final kind in <QueueOriginKind>[
        QueueOriginKind.discover,
        QueueOriginKind.search,
        QueueOriginKind.other,
      ]) {
        final p = build(origin: QueueOrigin(kind).toJson());
        final restored = QueueOrigin.fromJson(p['queueOrigin']);
        expect(restored, isNotNull);
        // 服务端无从解析 → serverContentType 必须为 null，回落整队推送。
        expect(restored!.serverContentType, isNull, reason: '$kind 不应可解析');
      }
    });

    test('旧版会话缺 queueOrigin 字段 / 脏数据一律降级为 null', () {
      expect(QueueOrigin.fromJson(null), isNull);
      expect(QueueOrigin.fromJson('playlist'), isNull);
      expect(QueueOrigin.fromJson(<String, dynamic>{}), isNull);
      expect(QueueOrigin.fromJson(<String, dynamic>{'kind': 42}), isNull);
      // 枚举名未知（未来新增种类后回滚旧版）：不抛、降级为整队推送。
      expect(
        QueueOrigin.fromJson(<String, dynamic>{'kind': 'brandNewKind'}),
        isNull,
      );
      // id 类型不符：保留 kind，丢掉非法 id → serverContentType 为 null。
      final loose = QueueOrigin.fromJson(
        <String, dynamic>{'kind': 'playlist', 'id': 99},
      );
      expect(loose, isNotNull);
      expect(loose!.id, isNull);
      expect(loose.serverContentType, isNull);
    });

    test('空 id 不写入 payload（避免落盘无意义的空串）', () {
      final p = build(origin: const QueueOrigin(QueueOriginKind.playlist, '').toJson());
      expect((p['queueOrigin'] as Map).containsKey('id'), isFalse);
      expect(QueueOrigin.fromJson(p['queueOrigin'])!.serverContentType, isNull);
    });

    // -----------------------------------------------------------------------
    // 恢复侧契约（readSessionQueueOrigin）
    //
    // 这组测试专门锁「写进去的东西读得出来」，且读写共用同一键名常量。
    // 背景：会话恢复在 _init() 内、需要真实 AudioService，纯测试驱动成本极高；
    // 历史上恢复侧回填逻辑**完全没有测试覆盖**——把回填整行删掉，全量测试
    // 依然全绿（已用变异验证确认）。这条漏洞直接导致「重启后大歌单搬移撞 403」
    // 静默存活。抽成纯函数后在此钉死。
    // -----------------------------------------------------------------------
    test('恢复侧：写进 payload 的来源能被原样读回（歌单→仍可走主通道）', () {
      final written = build(
        origin: const QueueOrigin(QueueOriginKind.playlist, 'pl-session').toJson(),
      );
      // 走真实的读取入口（而非直接下标访问），确保键名两侧一致。
      final raw = readSessionQueueOrigin(written);
      expect(raw, isNotNull, reason: '写入的来源必须能被读取入口取到');

      final restored = QueueOrigin.fromJson(raw);
      expect(restored!.kind, QueueOriginKind.playlist);
      expect(restored.id, 'pl-session');
      expect(restored.serverContentType, 'playlist');
    });

    test('恢复侧：旧版会话无来源字段 → null（降级整队推送，不误走主通道）', () {
      // 模拟修复前落盘的旧会话：只有队列相关字段，没有 queueOrigin。
      final legacy = <String, dynamic>{
        'version': 1,
        'queue': <Map<String, dynamic>>[],
        'currentIndex': 0,
        'currentSongId': 'a',
        'positionMs': 0,
        'isPlaying': false,
        'updatedAt': 1,
      };
      expect(readSessionQueueOrigin(legacy), isNull);
      expect(QueueOrigin.fromJson(readSessionQueueOrigin(legacy)), isNull);
    });

    test('恢复侧：往返链路的键名由同一常量定义（防止读写拼写漂移）', () {
      // 若有人把写入键改成 'origin' 而读取仍读 'queueOrigin'（或反之），
      // 这条断言会直接失败——这正是静默失效的典型形态。
      final written = build(
        origin: const QueueOrigin(QueueOriginKind.album, 'al-9').toJson(),
      );
      expect(written.containsKey(kSessionQueueOriginKey), isTrue);
      expect(readSessionQueueOrigin(written), isNotNull);
    });
  });
}