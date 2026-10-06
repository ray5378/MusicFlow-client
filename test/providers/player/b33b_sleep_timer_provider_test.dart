
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/sleep_timer_provider.dart';

import '../../features/player/test_player_notifier.dart';

/// 不触网假管理器(对齐 dlna_provider_test 的 _FakeManager)。
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
  Future<void> init({
    required Future<String> Function(String songId) streamUrlBuilder,
    Future<bool> Function(String songId)? probeSong,
  }) async {}

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
    if (from < 0 || from >= _queue.length || to < 0 || to > _queue.length) {
      return;
    }
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

/// 假投屏控制器:记录 pause / setSleepTimer 调用, 可选注入 activePeer 模拟链路 A。
class _FakeCastPeerController extends CastPeerController {
  _FakeCastPeerController(super.ref, {bool cast = false}) {
    if (cast) {
      state = state.copyWith(
        activePeer: const PeerInfo(
          peerId: 'p',
          name: 'n',
          kind: 'k',
          available: true,
        ),
      );
    }
  }

  bool pauseCalled = false;
  Duration? lastSetSleepTimer;
  bool clearedSleepTimer = false;

  @override
  Future<void> pause() async {
    pauseCalled = true;
  }

  @override
  Future<void> setSleepTimer(Duration? duration) async {
    if (duration == null) {
      clearedSleepTimer = true;
    } else {
      lastSetSleepTimer = duration;
    }
  }
}

ProviderContainer _container({bool cast = false}) => ProviderContainer(
      overrides: <Override>[
        dlnaManagerProvider.overrideWith((ref) => _FakeManager()),
        playerProvider.overrideWith(
          (ref) => TestPlayerNotifier(PlayerState()),
        ),
        castPeerControllerProvider.overrideWith(
          (ref) => _FakeCastPeerController(ref, cast: cast),
        ),
      ],
    );

void main() {
  test('start(本机): 设置倒计时, isActive=true, serverTracked=false', () async {
    final container = _container();
    addTearDown(container.dispose);
    final notifier = container.read(sleepTimerProvider.notifier);
    await notifier.start(const Duration(seconds: 10));
    expect(notifier.state, const Duration(seconds: 10));
    expect(notifier.isActive, isTrue);
    expect(notifier.serverTracked, isFalse);
  });

  test('cancel: 清空倒计时, isActive=false', () async {
    final container = _container();
    addTearDown(container.dispose);
    final notifier = container.read(sleepTimerProvider.notifier);
    await notifier.start(const Duration(seconds: 10));
    await notifier.cancel();
    expect(notifier.state, isNull);
    expect(notifier.isActive, isFalse);
  });

  test('start(投屏链路A): serverTracked=true 且下发服务器定时', () async {
    final container = _container(cast: true);
    addTearDown(container.dispose);
    final ctrl =
        container.read(castPeerControllerProvider.notifier)
            as _FakeCastPeerController;
    final notifier = container.read(sleepTimerProvider.notifier);
    await notifier.start(const Duration(seconds: 10));
    expect(notifier.serverTracked, isTrue);
    expect(ctrl.lastSetSleepTimer, const Duration(seconds: 10));
  });

  test('cancel(投屏链路A): 取消服务器侧定时', () async {
    final container = _container(cast: true);
    addTearDown(container.dispose);
    final ctrl =
        container.read(castPeerControllerProvider.notifier)
            as _FakeCastPeerController;
    final notifier = container.read(sleepTimerProvider.notifier);
    await notifier.start(const Duration(seconds: 10));
    await notifier.cancel();
    expect(ctrl.clearedSleepTimer, isTrue);
  });

  test('到期(本机): 到点本地暂停并清空倒计时', () async {
    final container = _container();
    addTearDown(container.dispose);
    final ctrl =
        container.read(castPeerControllerProvider.notifier)
            as _FakeCastPeerController;
    final notifier = container.read(sleepTimerProvider.notifier);
    await notifier.start(const Duration(milliseconds: 300));
    // 每秒 tick 在 ~1s 后首次触发, 此时已超过截止时间, 触发本地暂停。
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(ctrl.pauseCalled, isTrue);
    expect(notifier.state, isNull);
    expect(notifier.isActive, isFalse);
  });

  test('重复 start 重置时长', () async {
    final container = _container();
    addTearDown(container.dispose);
    final notifier = container.read(sleepTimerProvider.notifier);
    await notifier.start(const Duration(seconds: 10));
    await notifier.start(const Duration(seconds: 5));
    expect(notifier.state, const Duration(seconds: 5));
  });
}
