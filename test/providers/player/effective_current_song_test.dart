// effectiveCurrentSongProvider 行为锁（**阻塞**）。
//
// 语义（用户口径，2026-11-17）：歌词必须是**远端设备正在播的那首歌**的歌词。
//
// 为什么不能直接读 playerProvider.currentSong：投屏时本机队列只是远端队列的
// 镜像（syncQueueForCast），切换目标的那一两拍、或镜像轮询还没落地时，它仍是
// 上一首 —— 表现就是「设备已经播到 B 歌，通知栏挂着 A 歌的歌词」。
//
// 三条链路的真源：
//   - 链路 B（DLNA 直投）→ dlnaCastProvider.queue[currentIndex]
//   - 链路 A（后端投屏）→ castPeerControllerProvider.castQueue[castIndex]
//   - 本机            → playerProvider.currentSong（与原行为等价）
//
// 替身策略对齐 b34a：两个控制器都必须 `extends` 真类（否则类型检查不过），
// 只 override build() 返回固定 state；本机播放器用 test_player_notifier。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../features/player/test_player_notifier.dart';

class _StubCastPeer extends CastPeerController {
  _StubCastPeer({
    this.active = false,
    this.queue = const <Map<String, dynamic>>[],
    this.index = -1,
  });

  final bool active;
  final List<Map<String, dynamic>> queue;
  final int index;

  @override
  CastPeerState build() {
    if (!active) return super.build();
    return CastPeerState(
      activePeer: PeerInfo(
        peerId: 'peer-1',
        name: '客厅设备',
        kind: 'dlna',
        available: true,
      ),
      castQueue: queue,
      castIndex: index,
    );
  }
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast({
    this.casting = false,
    this.queue = const <DlnaCastTrack>[],
    this.index = -1,
  });

  final bool casting;
  final List<DlnaCastTrack> queue;
  final int index;

  @override
  DlnaCastState build() {
    if (!casting) return super.build();
    return DlnaCastState(
      isCasting: true,
      queue: queue,
      currentIndex: index,
    );
  }
}

Song _song(String id) => Song(id: id, title: '本机-$id', artist: '本机歌手');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer buildContainer({
    required TestPlayerNotifier player,
    CastPeerController? cast,
    DlnaCastNotifier? dlna,
  }) {
    return ProviderContainer(
      overrides: [
        playerProvider.overrideWith(() => player),
        castPeerControllerProvider.overrideWith(
          () => cast ?? _StubCastPeer(),
        ),
        dlnaCastProvider.overrideWith(() => dlna ?? _StubDlnaCast()),
      ],
    );
  }

  test('本机：取 playerProvider.currentSong', () {
    final player = TestPlayerNotifier(
      PlayerState(currentSong: _song('local-1')),
    );
    final container = buildContainer(player: player);
    addTearDown(container.dispose);

    expect(container.read(effectiveCurrentSongProvider)?.id, 'local-1');
  });

  test('链路 A：后端投屏队列的当前项优先于本机 currentSong', () {
    final player = TestPlayerNotifier(
      PlayerState(currentSong: _song('local-1')),
    );
    final container = buildContainer(
      player: player,
      cast: _StubCastPeer(
        active: true,
        index: 0,
        queue: const [
          {'songId': 'remote-9', 'title': '设备上的歌', 'artist': '设备歌手'},
        ],
      ),
    );
    addTearDown(container.dispose);

    final song = container.read(effectiveCurrentSongProvider);
    expect(song?.id, 'remote-9', reason: '歌词必须拉设备那首歌的');
    expect(song?.title, '设备上的歌');
  });

  test('链路 A：游标无效（目标空闲）时回退本机 currentSong', () {
    final player = TestPlayerNotifier(
      PlayerState(currentSong: _song('local-1')),
    );
    final container = buildContainer(
      player: player,
      cast: _StubCastPeer(
        active: true,
        index: -1,
        queue: const [
          {'songId': 'remote-9', 'title': '设备上的歌'},
        ],
      ),
    );
    addTearDown(container.dispose);

    expect(container.read(effectiveCurrentSongProvider)?.id, 'local-1');
  });

  test('链路 B：DLNA 投屏队列的当前项优先于本机 currentSong', () {
    final player = TestPlayerNotifier(
      PlayerState(currentSong: _song('local-1')),
    );
    final container = buildContainer(
      player: player,
      dlna: _StubDlnaCast(
        casting: true,
        index: 0,
        queue: const [
          DlnaCastTrack(songId: 'dlna-7', title: 'DLNA 上的歌', artist: 'DLNA 歌手'),
        ],
      ),
    );
    addTearDown(container.dispose);

    final song = container.read(effectiveCurrentSongProvider);
    expect(song?.id, 'dlna-7', reason: 'DLNA 当前曲的真源在设备队列里');
    expect(song?.artist, 'DLNA 歌手');
  });

  test('链路 B 优先于链路 A（两条同时成立时以直投为准，与 effective 三态一致）', () {
    final player = TestPlayerNotifier(
      PlayerState(currentSong: _song('local-1')),
    );
    final container = buildContainer(
      player: player,
      cast: _StubCastPeer(
        active: true,
        index: 0,
        queue: const [
          {'songId': 'remote-9', 'title': '设备上的歌'},
        ],
      ),
      dlna: _StubDlnaCast(
        casting: true,
        index: 0,
        queue: const [
          DlnaCastTrack(songId: 'dlna-7', title: 'DLNA 上的歌'),
        ],
      ),
    );
    addTearDown(container.dispose);

    expect(container.read(effectiveCurrentSongProvider)?.id, 'dlna-7');
  });
}
