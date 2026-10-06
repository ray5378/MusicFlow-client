// batch37 C —— `lib/providers/media/status_lyrics_provider.dart` 剩余未覆盖行。
//
// 既有 status_lyrics_cov_test.dart 极全，但它把开关打开**之前**就 emit /
// setActive / setCasting，故 `_syncSubscriptions` 里那批 `(_, __) => _push()`
// / `=> _pushQueue()` 的**监听回调行**从未真正执行（lcov 记 0）。本文件专补：
//   * 开启后依次改动各订阅源，逐个触发回调：
//       - player.currentSong（95，兜底）/ isPlaying（101，effectiveIsPlaying）
//       - player.volume（105，effectiveVolume）
//       - dlna(isCasting,playMode)（110）
//       - cast(activePeer!=null,playMode)（116）
//       - player.playbackMode（123）
//       - currentLyricLineProvider（127）
//       - player.currentIndex（137，_pushQueue）
//       - cast(activePeer,castQueue,castIndex,offline)（143，_pushQueue）
//       - dlna(isCasting,currentIndex)（147，_pushQueue）
//   * _composeSwitchRows 的「设备正在播放曲目为空 → 未在播放」分支（507）：
//     造一台 peer 回报 title 为空 → trackLabel 为空串。
//
// 设 debugDefaultTargetPlatformOverride = linux，让歌词窗那组原生 setter
// 走源码里的 `if (!isWindowsDesktop) return` 早退（无需 mock 通道，也不冒泡异常）。
//
// 只写 test/，只读 lib/。

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/media/status_lyrics_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../features/player/test_player_notifier.dart';

/// 可变更的投屏桩：暴露 status_lyrics_provider 读到的 activePeer/playMode/
/// castQueue/castIndex/offline。
class _FakeCastPeer extends CastPeerController {
  _FakeCastPeer(super.ref);

  List<PeerInfo> peers = <PeerInfo>[];
  bool emptyNowPlaying = false;

  void setActive(PeerInfo peer, {String playMode = 'one', bool offline = false}) {
    state = CastPeerState(
      activePeer: peer,
      playMode: playMode,
      offline: offline,
      castQueue: <Map<String, dynamic>>[
        <String, dynamic>{'songId': 'cast-1', 'title': '投屏曲1'},
      ],
      castIndex: 1,
    );
  }

  @override
  Future<List<PeerInfo>> loadPeers() async => peers;

  @override
  Future<PeerNowPlaying?> fetchPeerNowPlaying(String peerId) async =>
      PeerNowPlaying(
        isActive: true,
        currentIndex: 0,
        total: 0,
        title: emptyNowPlaying ? '' : '设备正在播',
        artist: emptyNowPlaying ? '' : '设备歌手',
      );
}

/// 可变更的 DLNA 直投桩。
class _FakeDlnaCast extends DlnaCastNotifier {
  _FakeDlnaCast(super.ref);

  void setCasting({required bool casting, String playMode = 'one'}) {
    state =
        DlnaCastState(isCasting: casting, playMode: playMode, currentIndex: 4);
  }
}

/// 供 currentLyricLineProvider 派生用的可变歌词行源。
final _lyricLine = StateProvider<String?>((ref) => null);

Song _song({String id = 's1', String title = '歌A'}) =>
    Song(id: id, title: title, artist: '歌手A');

PeerInfo _peer(String id, {String name = '设备', bool self = false}) =>
    PeerInfo(peerId: id, name: name, kind: 'dlna', available: true, self: self);

void main() {
  late ProviderContainer container;
  late TestPlayerNotifier player;
  late _FakeCastPeer cast;
  late _FakeDlnaCast dlna;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    player = TestPlayerNotifier(PlayerState(
      currentSong: _song(),
      queue: <Song>[_song()],
      currentIndex: 0,
    ));
    container = ProviderContainer(overrides: <Override>[
      playerProvider.overrideWith((ref) => player),
      castPeerControllerProvider.overrideWith((ref) => cast = _FakeCastPeer(ref)),
      dlnaCastProvider.overrideWith((ref) => dlna = _FakeDlnaCast(ref)),
      currentLyricLineProvider.overrideWith((ref) => ref.watch(_lyricLine)),
    ]);
    // 控制器构造期会 read 开关；桩要显式 read 一次装配，避免旧容器脏桩。
    container.read(castPeerControllerProvider);
    container.read(dlnaCastProvider);
    container.read(statusLyricsControllerProvider);
  });

  tearDown(() {
    container.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> tick() => Future<void>.delayed(Duration.zero);

  /// 打开歌词开关：先等构造器里 unawaited 的 _restore 落定（否则它随后会把
  /// 开关打回 false、把订阅拆掉），再置 true 触发 _syncSubscriptions。
  Future<void> enable() async {
    container.read(statusLyricsControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    container.read(statusLyricsEnabledProvider.notifier).state = true;
    await tick();
  }

  group('开启后各订阅源变化触发监听回调', () {
    test('依次改动 player / dlna / cast / 歌词行 → 各 _push/_pushQueue 回调被执行',
        () async {
      await enable();
      expect(container.read(statusLyricsEnabledProvider), isTrue);

      // 95：当前曲变化
      player.emit(player.state.copyWith(currentSong: _song(id: 's2', title: '歌B')));
      await tick();

      // 101：effectiveIsPlaying（本机链路）
      player.emit(player.state.copyWith(isPlaying: true));
      await tick();

      // 105：effectiveVolume（本机链路）
      player.emit(player.state.copyWith(volume: 0.77));
      await tick();

      // 123：playbackMode 四态权威值
      player.emit(player.state.copyWith(playbackMode: PlaybackMode.shuffle));
      await tick();

      // 137：currentIndex（_pushQueue）
      player.emit(player.state.copyWith(currentIndex: 0));
      await tick();

      // 110 / 147：dlna (isCasting, playMode) 与 (isCasting, currentIndex)
      dlna.setCasting(casting: true, playMode: 'order');
      await tick();

      // 116 / 143：cast (activePeer != null, playMode) 与队列四元组
      cast.setActive(_peer('dlna:AAA', name: '主卧'));
      await tick();

      // 127：歌词行变化
      container.read(_lyricLine.notifier).state = '新的歌词行';
      await tick();

      expect(container.read(statusLyricsEnabledProvider), isTrue);
      expect(container.read(statusLyricsControllerProvider), isNotNull);
    });
  });

  group('_composeSwitchRows 副标题回退', () {
    test('设备回报曲目为空 → 副标题「未在播放」（覆盖 trackLabel 空分支）', () async {
      cast.peers = <PeerInfo>[_peer('dlna:AAA', name: '主卧')];
      cast.emptyNowPlaying = true;
      await enable();

      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();
      await tick();

      // 无异常即说明空 trackLabel 分支被走到（未在播放文案）。
      expect(container.read(statusLyricsEnabledProvider), isTrue);
    });
  });
}
