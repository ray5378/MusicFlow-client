import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/dlna_provider.dart';
import 'package:musicflow_client/providers/player_provider.dart';

import '../features/player/test_player_notifier.dart';

/// 不触网假管理器：在内存中维护投屏队列/游标，精确复刻链路 B 的
/// enqueue/remove/reorder 语义（对齐链路 A），供 notifier 的状态同步测试。
class _FakeManager extends DlnaManager {
  List<DlnaCastTrack> _queue = [];
  int _index = -1;
  bool _casting = false;

  @override
  bool get isCasting => _casting;

  @override
  List<DlnaCastTrack> get castQueue => List.unmodifiable(_queue);

  @override
  int get castQueueIndex => _index;

  @override
  Future<void> init({required String Function(String songId) streamUrlBuilder}) async {
    // 静默：测试环境不建 SSDP 套接字 / HTTP 中继。
  }

  @override
  Future<bool> startCast(
    DlnaDevice device,
    List<DlnaCastTrack> tracks, {
    int startIndex = 0,
  }) async {
    _queue = List.of(tracks);
    _index = startIndex;
    _casting = true;
    return true;
  }

  @override
  Future<void> stopCast() async {
    _queue = [];
    _index = -1;
    _casting = false;
    onCastDisconnected?.call();
  }

  @override
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _index = index;
    onTrackChanged?.call(_index);
  }

  @override
  Future<void> enqueueSongs(List<DlnaCastTrack> tracks) async {
    if (tracks.isEmpty) return;
    _queue = [..._queue, ...tracks];
    onTrackChanged?.call(_index);
  }

  @override
  Future<void> removeQueueItem(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _queue = List.of(_queue)..removeAt(index);
    if (_queue.isEmpty) {
      await stopCast();
      return;
    }
    if (index < _index) {
      _index--;
    } else if (_index >= _queue.length) {
      _index = _queue.length - 1;
    }
    onTrackChanged?.call(_index);
  }

  @override
  Future<void> reorderQueue(int from, int to) async {
    if (from < 0 || from >= _queue.length || to < 0 || to > _queue.length) return;
    if (from == to) return;
    final current = from == _index ? _queue[from] : _queue[_index];
    _queue = List.of(_queue);
    final item = _queue.removeAt(from);
    final insertAt = to > from ? to - 1 : to;
    _queue.insert(insertAt, item);
    _index = from == _index ? insertAt : _queue.indexOf(current);
    onTrackChanged?.call(_index);
  }
}

DlnaDevice _device(String id, String name) => DlnaDevice(
      id: id,
      name: name,
      location: 'http://192.168.1.10:8000/desc.xml',
      lastSeen: DateTime(2024, 1, 1),
      avTransportUrl: 'http://192.168.1.10:8000/AVTransport/control',
      renderingControlUrl: 'http://192.168.1.10:8000/RenderingControl/control',
    );

DlnaCastTrack _track(String songId, String title) =>
    DlnaCastTrack(songId: songId, title: title, artist: '周杰伦');

Song _song(String id, String title) => Song(id: id, title: title, artist: '周杰伦');

PlayerState _playerState(List<Song> queue) => PlayerState(
      currentSong: queue.isEmpty ? null : queue.first,
      queue: queue,
      currentIndex: queue.isEmpty ? -1 : 0,
      isPlaying: true,
      position: Duration.zero,
      duration: Duration.zero,
      bufferedPosition: Duration.zero,
      loopMode: LoopMode.all,
      currentQuality: AudioQualityLevel.original,
      playbackSource: PlaybackSource.stream,
      currentBitRateKbps: 320,
    );

void main() {
  final device = _device('u1', '客厅电视');
  final sourceSongs = <Song>[
    _song('s1', '夜曲'),
    _song('s2', '晴天'),
    _song('s3', '七里香'),
  ];

  late _FakeManager manager;
  late ProviderContainer container;
  late DlnaCastNotifier notifier;

  setUp(() {
    manager = _FakeManager();
    container = ProviderContainer(
      overrides: [
        dlnaManagerProvider.overrideWith((ref) => manager),
        playerProvider.overrideWith((ref) => TestPlayerNotifier(_playerState(sourceSongs))),
      ],
    );
    notifier = container.read(dlnaCastProvider.notifier);
  });

  tearDown(() => container.dispose());

  Future<void> startCast() async {
    final ok = await notifier.startCast(
      device,
      sourceSongs.map((s) => _track(s.id, s.title)).toList(),
    );
    expect(ok, isTrue);
  }

  group('dlnaCastProvider 投屏队列（对齐链路 A）', () {
    test('startCast 进入投屏态并镜像队列到本机', () async {
      await startCast();

      final st = container.read(dlnaCastProvider);
      expect(st.isCasting, isTrue);
      expect(st.currentDevice?.id, 'u1');
      expect(st.queue.length, 3);
      expect(st.currentIndex, 0);
      // 本机队列被镜像为投屏队列（全屏封面/歌词跟随设备）。
      expect(container.read(playerProvider).queue.length, 3);
    });

    test('enqueueSongs 追加到投屏队列末尾且游标不变', () async {
      await startCast();

      await notifier.enqueueSongs([_song('s4', '稻香')]);

      final st = container.read(dlnaCastProvider);
      expect(st.queue.length, 4);
      expect(st.queue[3].songId, 's4');
      expect(st.currentIndex, 0, reason: '追加不应改变当前曲目');
      expect(manager.castQueue.length, 4);
    });

    test('removeQueueItem 移除当前曲之后的曲目不改变游标', () async {
      await startCast();

      await notifier.removeQueueItem(2); // 移除下标 2（当前为 0）

      final st = container.read(dlnaCastProvider);
      expect(st.queue.length, 2);
      expect(st.queue[0].songId, 's1');
      expect(st.currentIndex, 0);
      // 本机镜像队列同步收缩。
      expect(container.read(playerProvider).queue.length, 2);
    });

    test('removeQueueItem 移除当前曲之前的曲目游标前移', () async {
      await startCast();
      await notifier.playAt(2); // 切到「七里香」

      await notifier.removeQueueItem(0); // 移除「夜曲」

      final st = container.read(dlnaCastProvider);
      expect(st.queue.map((t) => t.songId), ['s2', 's3']);
      expect(st.currentIndex, 1, reason: '移除当前曲之前应整体前移');
    });

    test('removeQueueItem 移除全部曲目后退出投屏态', () async {
      await startCast();

      await notifier.removeQueueItem(0);
      await notifier.removeQueueItem(0);
      await notifier.removeQueueItem(0);

      final st = container.read(dlnaCastProvider);
      expect(st.isCasting, isFalse);
      expect(st.queue, isEmpty);
      expect(st.currentIndex, -1);
      expect(manager.isCasting, isFalse);
    });

    test('reorderQueue 拖动当前曲目到队尾时游标跟随', () async {
      await startCast(); // 当前为 s1 (index 0)

      await notifier.reorderQueue(0, 3); // 把「夜曲」拖到队列末尾

      final st = container.read(dlnaCastProvider);
      expect(st.queue.map((t) => t.songId), ['s2', 's3', 's1']);
      expect(st.currentIndex, 2, reason: '拖动的正是当前曲，游标跟随到末尾');
    });

    test('reorderQueue 游标位于拖动位置之前时前移', () async {
      await startCast();
      await notifier.playAt(2); // 当前 s3 (index 2)

      await notifier.reorderQueue(0, 3); // 把 s1 从队首拖到队尾(越过当前)

      final st = container.read(dlnaCastProvider);
      expect(st.queue.map((t) => t.songId), ['s2', 's3', 's1']);
      expect(st.currentIndex, 1, reason: '游标之前的曲目被越过后前移');
      expect(manager.castQueueIndex, 1);
    });
  });
}