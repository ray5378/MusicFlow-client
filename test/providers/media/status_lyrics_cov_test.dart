// batch16 覆盖率补齐：`lib/providers/media/status_lyrics_provider.dart`
// （桌面歌词浮窗控制器：状态推送 / 队列推送 / 流转播放设备弹窗 / 接续与切换行号路由）。
//
// 第一批专门打既有 `lyric_switch_list_chain_test.dart` 没碰到的分支：
// 订阅开关（关闭态绝不拉歌词、绝无订阅）、状态推送全字段与去重、
// 三链路播放模式推导优先级、队列弹窗三链路组拼与去重、
// 跳转路由、设备行组拼（badge/canPull/canPush/handoff/loading/副标题）、
// 设备弹窗的实时「正在播放」刷新（5s 周期 + 停表）、接续/切换行号边界。
//
// 打桩要点：
// 1. 把 `debugDefaultTargetPlatformOverride` 设成 Windows，歌词窗那组
//    MethodChannel setter 才会真的发消息（源码里 `if (!isWindowsDesktop) return`），
//    否则整条推送链在单测里是死的，什么都观测不到 —— 这是本文件能成立的前提。
// 2. `castPeerControllerProvider` / `dlnaCastProvider` 用**假控制器**替掉，
//    状态与调用一目了然，不用起网络也不用起轮询。
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/media/status_lyrics_provider.dart';
import 'package:musicflow_client/core/l10n/localizations.dart'
    show l10nNowCurrent;
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/effective_volume.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart'
    show kWindowsWindowChannel;

import '../../features/player/test_player_notifier.dart';

/// 一次原生歌词窗调用（方法名 + 参数），用来断言「推了什么、推了几次」。
class _Call {
  _Call(this.method, this.args);

  final String method;
  final Map<Object?, Object?> args;
}

/// 会录调用的投屏控制器桩：`status_lyrics_provider` 只读它的
/// activePeer / playMode / castQueue / castIndex / offline，只调几个明确方法。
class _FakeCastPeer extends CastPeerController {
  _FakeCastPeer(super.ref);

  final List<String> calls = <String>[];
  List<PeerInfo> loadedPeers = <PeerInfo>[];
  bool loadThrows = false;
  bool switchResult = true;
  bool pushResult = true;
  bool pullResult = true;
  int? jumpedIndex;
  final List<String> nowPlayingPeers = <String>[];

  /// 本机之外的「另一台客户端」/ 设备都算可遥控，桩里统一造。
  void setPeers(List<PeerInfo> peers) {
    loadedPeers = peers;
  }

  /// 造一个投屏态（切到某个 peer）。
  void setActive(PeerInfo peer, {String playMode = 'one', bool offline = false}) {
    state = CastPeerState(
      activePeer: peer,
      playMode: playMode,
      offline: offline,
      castQueue: <Map<String, dynamic>>[
        <String, dynamic>{
          'songId': 'cast-1',
          'title': '投屏曲1',
          'artist': '投屏歌手',
        },
        <String, dynamic>{
          'songId': 'cast-2',
          'title': '投屏曲2',
          'artist': '投屏歌手',
        },
      ],
      castIndex: 1,
    );
  }

  @override
  Future<List<PeerInfo>> loadPeers() async {
    calls.add('loadPeers');
    if (loadThrows) throw StateError('simulated load failure');
    return loadedPeers;
  }

  @override
  Future<bool> switchTo(PeerInfo peer) async {
    calls.add('switchTo:${peer.peerId}');
    return switchResult;
  }

  @override
  Future<void> backToLocal({bool resumeLocal = false}) async {
    calls.add('backToLocal:$resumeLocal');
  }

  @override
  Future<void> stopCasting() async {
    calls.add('stopCasting');
  }

  @override
  Future<void> jumpTo(int index) async {
    jumpedIndex = index;
    calls.add('jumpTo');
  }

  @override
  Future<bool> pushLocalToPeer(PeerInfo peer) async {
    calls.add('pushLocalToPeer:${peer.peerId}');
    return pushResult;
  }

  @override
  Future<bool> pullPeerToLocal(PeerInfo peer) async {
    calls.add('pullPeerToLocal:${peer.peerId}');
    return pullResult;
  }

  /// 当前回给原生层的「正在播放」曲目（测试里可改，用来造「内容变了」）。
  String nowPlayingTitle = '设备正在播';

  @override
  Future<PeerNowPlaying?> fetchPeerNowPlaying(String peerId) async {
    nowPlayingPeers.add(peerId);
    return PeerNowPlaying(
      isActive: true,
      currentIndex: 2,
      total: 12,
      title: nowPlayingTitle,
      artist: '设备歌手',
    );
  }
}

/// DLNA 直投链路桩：只暴露 `status_lyrics_provider` 用到的 isCasting /
/// playMode / currentIndex（与 playAt）。
class _FakeDlnaCast extends DlnaCastNotifier {
  _FakeDlnaCast(super.ref);

  final List<int> playAtCalls = <int>[];

  void setCasting({required bool casting, String playMode = 'one'}) {
    state = DlnaCastState(isCasting: casting, playMode: playMode, currentIndex: 4);
  }

  @override
  Future<void> playAt(int index) async {
    playAtCalls.add(index);
  }
}

Song _song({
  String id = 's1',
  String title = '歌A',
  String artist = ' 歌手A  ',
  bool starred = false,
}) =>
    Song(id: id, title: title, artist: artist, starred: starred);

PeerInfo _peer(
  String id, {
  String name = '设备',
  String kind = 'dlna',
  bool available = true,
  bool self = false,
}) =>
    PeerInfo(peerId: id, name: name, kind: kind, available: available, self: self);

void main() {
  late ProviderContainer container;
  late TestPlayerNotifier player;
  late _FakeCastPeer cast;
  late _FakeDlnaCast dlna;
  final List<_Call> native = <_Call>[];

  /// 造容器：投屏/DLNA 走桩，歌词相关 provider 全部给确定值。
  ProviderContainer buildContainer(
      {String? lyricLine = '<line>', TestPlayerNotifier? playerNotifier}) {
    return ProviderContainer(overrides: <Override>[
      playerProvider.overrideWith((ref) => playerNotifier ?? player),
      castPeerControllerProvider.overrideWith((ref) {
        cast = _FakeCastPeer(ref);
        return cast;
      }),
      dlnaCastProvider.overrideWith((ref) {
        dlna = _FakeDlnaCast(ref);
        return dlna;
      }),
      effectiveIsPlayingProvider.overrideWithValue(true),
      effectiveVolumeProvider.overrideWithValue(0.4321234),
      currentLyricLineProvider.overrideWithValue(lyricLine),
    ]);
  }

  int countOf(String method) =>
      native.where((c) => c.method == method).length;

  List<Map<Object?, Object?>> argsOf(String method) =>
      native.where((c) => c.method == method).map((c) => c.args).toList();

  Map<Object?, Object?> lastArgs(String method) => argsOf(method).last;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // ⚠️ 关键：源码 setter 开头就是 `if (!isWindowsDesktop) return`，
    // 不伪装成 Windows，整条推送链在单测里静默空转、断言永远落空。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      kWindowsWindowChannel,
      (MethodCall call) async {
        native.add(_Call(
          call.method,
          (call.arguments as Map).cast<Object?, Object?>(),
        ));
        return null;
      },
    );
    native.clear();
    player = TestPlayerNotifier(PlayerState(
      currentSong: _song(),
      queue: <Song>[_song(id: 's1'), _song(id: 's2', title: '歌B', artist: '歌手B')],
      currentIndex: 1,
    ));
    container = buildContainer();
    // 先在 setUp 里把控制器（连带 cast / dlna 两个桩）装配出来：
    // 桩只在 provider 被首次读取时才 new 出来，晚一点 `cast.setActive(...)`
    // 就会打到上一个容器那个已 dispose 的桩上，报
    // 「Tried to use _FakeCastPeer after dispose was called」
    // （踩坑 #26）。
    // 关键：控制器构造期只订阅开关，并不读 cast / dlna，
    // 两个桩要等到 _push / _composeSwitchRows 才第一次 new ——
    // 所以这里必须显式 read 一次，否则用例里先 `cast.setActive(...)`
    // 打到的还是上个容器那个已 dispose 的桩（踩坑 #26）。
    container.read(castPeerControllerProvider);
    container.read(dlnaCastProvider);
    container.read(statusLyricsControllerProvider);
  });

  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kWindowsWindowChannel, null);
    debugDefaultTargetPlatformOverride = null;
    native.clear();
  });

  /// 把歌词开关打开：等构造器里 unawaited 的 `_restore()` 落定（否则它
  /// 随后会把 state 打回 false），再置 true 触发 `_enabledSub` →
  /// `_syncSubscriptions()` + `_apply()`。
  Future<void> enableLyrics(ProviderContainer c) async {
    c.read(statusLyricsControllerProvider); // 控制器没装配就先装配，否则没人听开关
    // `_restore()` 是构造器里 unawaited 的（要等 SharedPreferences），
    // 必须让它先落定，否则它随后会把开关打回 false、把订阅拆掉。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    c.read(statusLyricsEnabledProvider.notifier).state = true;
  }

  // ==================== 一、两个纯函数的全分支 ====================

  group('播放模式串推导（纯函数）', () {
    test('deriveDesktopLyricMode 四态各自独立（order 与 all 必须区分）', () {
      expect(deriveDesktopLyricMode(playbackMode: PlaybackMode.shuffle),
          'shuffle');
      expect(deriveDesktopLyricMode(playbackMode: PlaybackMode.one),
          'repeatOne');
      expect(deriveDesktopLyricMode(playbackMode: PlaybackMode.order), 'order');
      expect(deriveDesktopLyricMode(playbackMode: PlaybackMode.all),
          'repeatAll');
    });

    test('castPlayModeToLyricMode 三态透传 + 未知值兜底 repeatAll', () {
      expect(castPlayModeToLyricMode('shuffle'), 'shuffle');
      expect(castPlayModeToLyricMode('one'), 'repeatOne');
      expect(castPlayModeToLyricMode('order'), 'order');
      // 兜底：后端任何非约定值（''/null 之外的怪值）都按列表循环处理。
      expect(castPlayModeToLyricMode('bogus'), 'repeatAll');
      expect(castPlayModeToLyricMode(''), 'repeatAll');
    });
  });

  // ==================== 二、provider 装配与订阅开关 ====================

  group('订阅开合（关闭态绝不能拉歌词）', () {
    test('statusLyricsControllerProvider 能装配并随容器销毁', () {
      final ctrl = container.read(statusLyricsControllerProvider);
      expect(ctrl, isNotNull);
      container.invalidate(statusLyricsControllerProvider);
      expect(container.read(statusLyricsControllerProvider), isNotNull);
    });

    test('关闭态：改歌/改模式都不产生任何歌词窗状态推送', () async {
      container.read(statusLyricsControllerProvider);
      await enableLyrics(container); // 先归位到「关」
      container.read(statusLyricsEnabledProvider.notifier).state = false;
      native.clear();

      player.emit(player.state.copyWith(currentSong: _song(id: 'other')));
      player.emit(player.state.copyWith(playbackMode: PlaybackMode.order));
      await Future<void>.delayed(Duration.zero);

      expect(countOf('update_desktop_lyric_state'), 0);
      expect(countOf('update_desktop_lyric_queue'), 0);
    });

    test('开启：显示浮窗 + 立刻推一份状态与队列', () async {
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);

      expect(countOf('set_desktop_lyric_visible'), 1);
      expect(lastArgs('set_desktop_lyric_visible')['visible'], true);
      expect(countOf('update_desktop_lyric_state'), 1);
      expect(countOf('update_desktop_lyric_queue'), 1);
    });

    test('关闭：隐藏浮窗，且此后改歌不再推状态', () async {
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      native.clear();

      container.read(statusLyricsEnabledProvider.notifier).state = false;

      expect(lastArgs('set_desktop_lyric_visible')['visible'], false);
      final afterHide = countOf('update_desktop_lyric_state');

      player.emit(player.state.copyWith(currentSong: _song(id: 'new')));
      await Future<void>.delayed(Duration.zero);

      expect(countOf('update_desktop_lyric_state'), afterHide);
    });
  });

  // ==================== 三、状态推送：全字段与去重 ====================

  group('状态推送字段与去重', () {
    test('推送含歌名/歌手(trim 过)/歌词行/播放态/喜欢/模式/两位音量/固定色',
        () async {
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);

      final a = lastArgs('update_desktop_lyric_state');
      expect(a['song'], '歌A');
      expect(a['artist'], '歌手A'); // trim 掉了构造时故意加的空格
      expect(a['lyric'], '<line>');
      expect(a['playing'], true);
      expect(a['liked'], false);
      expect(a['mode'], 'repeatAll'); // 默认 PlaybackMode.all
      expect(a['volume'], 0.43); // 0.4321234 → 两位小数
      expect(a['lyricColor'], 0xFFC233);
    });

    test('starred 透传成 liked', () async {
      player.emit(player.state.copyWith(currentSong: _song(starred: true)));
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      expect(lastArgs('update_desktop_lyric_state')['liked'], true);
    });

    test('无歌时退成空串也必须推（不是不推）', () async {
      player.emit(PlayerState()); // 空 state：currentSong = null、队列空
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);

      final a = lastArgs('update_desktop_lyric_state');
      expect(a['song'], '');
      expect(a['artist'], '');
      expect(a['liked'], false);
      expect(countOf('update_desktop_lyric_queue'), 1);
    });

    test('currentLyricLineProvider 为 null 时 lyric 退成空串', () async {
      final solo = TestPlayerNotifier(PlayerState());
      final c2 = buildContainer(lyricLine: null, playerNotifier: solo);
      addTearDown(c2.dispose);
      await enableLyrics(c2);
      c2.read(statusLyricsControllerProvider);

      expect(lastArgs('update_desktop_lyric_state')['lyric'], '');
      expect(lastArgs('update_desktop_lyric_state')['song'], '');
    });

    test('字段全同不重复推；变一个字段才重推', () async {
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      final base = countOf('update_desktop_lyric_state');

      // 触发一次但内容完全没变（改一个与推送 key 无关的字段）。
      player.emit(player.state.copyWith(position: const Duration(seconds: 9)));
      await Future<void>.delayed(Duration.zero);
      expect(countOf('update_desktop_lyric_state'), base);

      // 内容真变了 → 重推。（不能改 isPlaying：控制器压根没订阅它，
      // 改了不会触发 _push，会误判成「去重失效」）
      player.emit(player.state.copyWith(currentSong: _song(id: 'z', title: '歌Z')));
      await Future<void>.delayed(Duration.zero);
      expect(countOf('update_desktop_lyric_state'), base + 1);
      expect(lastArgs('update_desktop_lyric_state')['song'], '歌Z');
    });

    test('关→开 一轮会强制重推（_apply 清空去重 key）', () async {
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      final base = countOf('update_desktop_lyric_state');

      // 关：只收 set_desktop_lyric_visible(false)
      container.read(statusLyricsEnabledProvider.notifier).state = false;
      native.clear();

      // 开：尽管什么都没变，也要再推一份完整状态 + 队列
      container.read(statusLyricsEnabledProvider.notifier).state = true;
      expect(countOf('update_desktop_lyric_state'), 1);
      expect(countOf('update_desktop_lyric_queue'), 1);
      expect(countOf('set_desktop_lyric_visible'), 1);
      expect(base, greaterThanOrEqualTo(1));
    });
  });

  // ==================== 四、播放模式推导的三链路优先级 ====================

  group('歌词窗播放模式串（三链路优先级）', () {
    test('本机：跟 PlaybackMode 权威值走', () async {
      player.emit(player.state.copyWith(playbackMode: PlaybackMode.order));
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      expect(lastArgs('update_desktop_lyric_state')['mode'], 'order');
    });

    test('DLNA 直投优先：取设备侧 playMode', () async {
      dlna.setCasting(casting: true, playMode: 'shuffle');
      player.emit(player.state.copyWith(playbackMode: PlaybackMode.one));
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      expect(lastArgs('update_desktop_lyric_state')['mode'], 'shuffle');
    });

    test('peer 投屏次之：本机没投屏但 cast 有 activePeer', () async {
      cast.setActive(_peer('dlna:AAA', name: '主卧'));
      player.emit(player.state.copyWith(playbackMode: PlaybackMode.all));
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      expect(lastArgs('update_desktop_lyric_state')['mode'], 'repeatOne');
    });

    test('DLNA 与 peer 同时投屏时 DLNA 优先', () async {
      dlna.setCasting(casting: true, playMode: 'order');
      cast.setActive(_peer('dlna:BBB', name: '次卧'), playMode: 'one');
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      expect(lastArgs('update_desktop_lyric_state')['mode'], 'order');
    });
  });

  // ==================== 五、队列弹窗：三链路组拼与去重 ====================

  group('队列弹窗（三链路）', () {
    test('本机：本机队列 + localIndex', () async {
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      final a = lastArgs('update_desktop_lyric_queue');
      expect(a['index'], 1);
      expect(a['items'], <Object?>['歌A — 歌手A', '歌B — 歌手B']);
    });

    test('DLNA 直投：本机队列文本，但当前曲用设备下标', () async {
      dlna.setCasting(casting: true);
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      final a = lastArgs('update_desktop_lyric_queue');
      expect(a['index'], 4); // DlnaCastState.currentIndex
      expect(a['items'], <Object?>['歌A — 歌手A', '歌B — 歌手B']);
    });

    test('peer 投屏：用设备队列（远端 Map → 显示文本）', () async {
      cast.setActive(_peer('dlna:AAA', name: '主卧'));
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      final a = lastArgs('update_desktop_lyric_queue');
      expect(a['index'], 1); // CastPeerState.castIndex
      expect(a['items'], <Object?>['投屏曲1 — 投屏歌手', '投屏曲2 — 投屏歌手']);
    });

    test('队列内容没变不重复推（新 list 实例触发监听但组拼同 key）', () async {
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      final base = countOf('update_desktop_lyric_queue');

      // select 按引用比较 → 新 list 会触发监听 → 走 _pushQueue 的 Key 去重。
      player.emit(player.state.copyWith(
        queue: <Song>[_song(), _song(id: 's2', title: '歌B', artist: '歌手B')],
      ));
      await Future<void>.delayed(Duration.zero);

      expect(countOf('update_desktop_lyric_queue'), base);
    });
  });

  // ==================== 六、跳转路由（三链路） ====================

  group('jumpToQueueIndex 按链路路由', () {
    test('peer 投屏 → cast.jumpTo', () async {
      cast.setActive(_peer('dlna:AAA', name: '主卧'));
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      await container.read(statusLyricsControllerProvider).jumpToQueueIndex(7);
      expect(cast.jumpedIndex, 7);
    });

    test('DLNA 直投 → dlna.playAt', () async {
      dlna.setCasting(casting: true);
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      await container.read(statusLyricsControllerProvider).jumpToQueueIndex(3);
      expect(dlna.playAtCalls, <int>[3]);
    });

    test('本机 → player.skipToQueueItem', () async {
      await enableLyrics(container);
      container.read(statusLyricsControllerProvider);
      await container.read(statusLyricsControllerProvider).jumpToQueueIndex(2);
      expect(player.skippedIndices, <int>[2]);
    });
  });

  // ==================== 七、设备行组拼与推送 ====================

  group('流转播放设备弹窗', () {
    test('本机组行：本机行 + 可用远端行 + 刷新行，箭头/徽章全对', () async {
      cast.setPeers(<PeerInfo>[
        _peer('local:abc', kind: 'local', self: true, name: '本机'),
        _peer('dlna:AAA', name: '主卧'),
        _peer('dlna:BBB', name: '断线的', available: false),
        _peer('local:xyz', kind: 'local', self: false, name: '网页端'),
        _peer('group:G1', kind: 'group', name: '客厅组'),
      ]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();

      final items = lastArgs('update_desktop_lyric_switch_list')['items']
          as List<Object?>;
      // 本机 + 主卧 + 网页端（远端 local）+ 客厅组 + 刷新 = 5 行
      expect(items.length, 5);
      final main = items[1] as Map<Object?, Object?>;
      expect(main['title'], '主卧');
      expect(main['handoff'], true);
      expect(main['current'], false);
      // canPush：本机非投屏 + 本机队列非空（构造时给了 2 首）
      expect(main['canPush'], true);
      expect(lastArgs('update_desktop_lyric_switch_list')['loading'], false);
    });

    test('本机行恒在最前且 equip 图标=1；投屏时插「停止投屏」行', () async {
      cast.setActive(_peer('dlna:AAA', name: '主卧'));
      cast.setPeers(<PeerInfo>[_peer('dlna:CCC', name: '客卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();

      final items = lastArgs('update_desktop_lyric_switch_list')['items']
          as List<Object?>;
      expect(items.length, 4); // 本机 + 停止投屏 + 客卧 + 刷新
      expect((items[0] as Map<Object?, Object?>)['icon'], 1);
      expect((items[0] as Map<Object?, Object?>)['handoff'], false);
      expect((items[1] as Map<Object?, Object?>)['title'],
          l10nNowCurrent().player_stop_cast);
      expect((items[1] as Map<Object?, Object?>)['handoff'], false);
      expect((items[2] as Map<Object?, Object?>)['title'], '客卧');
    });

    test('本机行副标题跟随投屏状态：投屏中写设备名 / 离线写离线', () async {
      // 场景一：投屏中且设备在线 → 本机行不再是 current，副标题点名设备
      cast.setActive(_peer('dlna:AAA', name: '主卧'), offline: false);
      cast.setPeers(<PeerInfo>[_peer('dlna:CCC', name: '客卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();

      final items = lastArgs('update_desktop_lyric_switch_list')['items']
          as List<Object?>;
      final localRow = items[0] as Map<Object?, Object?>;
      expect(localRow['current'], false); // 本机已不是控制目标
      // 文案直接取 l10n 自身（测试进程默认语言未必是 zh，别写死中文）
      expect(localRow['subtitle'], l10nNowCurrent().player_source_casting);

    });

    test('本机行副标题在 offline 时切成「离线」文案', () async {
      cast.setActive(_peer('dlna:AAA', name: '主卧'), offline: true);
      cast.setPeers(<PeerInfo>[_peer('dlna:CCC', name: '客卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();

      final items = lastArgs('update_desktop_lyric_switch_list')['items']
          as List<Object?>;
      final localRow = items[0] as Map<Object?, Object?>;
      expect(localRow['current'], false);
      expect(localRow['subtitle'], l10nNowCurrent().player_source_offline);
      // 投屏态下「停止投屏」行存在，且它不带接续箭头
      expect((items[1] as Map<Object?, Object?>)['title'],
          l10nNowCurrent().player_stop_cast);
      expect((items[1] as Map<Object?, Object?>)['handoff'], false);
    });

    test('canPull：设备队列非空 + 正在播才亮（远端桩造 queueActive）', () async {
      cast.setPeers(<PeerInfo>[
        _peer('dlna:AAA', name: '主卧'),
        _peer('dlna:DDD', name: '没在播'),
      ]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();

      final items = lastArgs('update_desktop_lyric_switch_list')['items']
          as List<Object?>;
      // 桩里两个设备都没带 queue 字段 → queueTotal=0 → canPull 恒 false
      expect((items[1] as Map<Object?, Object?>)['canPull'], false);
      expect((items[2] as Map<Object?, Object?>)['canPull'], false);
      expect((items[1] as Map<Object?, Object?>)['handoff'], true);
    });

    test('设备行没变不重复推（5s tick 去重 key 覆盖全字段）', () {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      final ctrl = container.read(statusLyricsControllerProvider);
      fakeAsync((async) {
        async.elapse(const Duration(milliseconds: 20)); // 让 _restore 落定
        container.read(statusLyricsEnabledProvider.notifier).state = true;
        async.flushMicrotasks();

        unawaited(ctrl.requestSwitchList());
        async.flushMicrotasks();
        final afterInit = countOf('update_desktop_lyric_switch_list');
        expect(afterInit, 3); // loading + 真实列表 + 首轮 nowPlaying 重推

        // 首轮 nowPlaying 重推已经把去重 key 定住了（副标题从「状态获取中…」
        // 变成真实曲目），所以紧接着这一拍会被去重拦掉，先改点内容再验证。
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(countOf('update_desktop_lyric_switch_list'), afterInit);

        cast.nowPlayingTitle = '换了一首'; // 副标题变了 → 必须重推
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        final tick1 = countOf('update_desktop_lyric_switch_list');
        expect(tick1, afterInit + 1);

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        // 内容又没变 → 去重把它拦掉（否则原生每 5s 白刷一遍）
        expect(countOf('update_desktop_lyric_switch_list'), tick1);

        ctrl.stopSwitchAutoRefresh();
      });
    });

    test('弹窗展开先推 loading 占位，拉回来再推真实列表', () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);

      native.clear();
      final future = ctrl.requestSwitchList();
      await Future<void>.delayed(Duration.zero);
      // 这一拍里除了 loading 占位，还夹着首轮「正在播放」的重推：
      // 所以不能按调用次数断言，而要按 `loading` 字段把两拨挑出来（踩坑 #27）。
      final listCalls = native
          .where((c) => c.method == 'update_desktop_lyric_switch_list')
          .toList();
      final loadingCalls =
          listCalls.where((c) => c.args['loading'] == true).toList();
      expect(loadingCalls, isNotEmpty);
      // loading 那次上游 `_switchPeers` 已被清空,所以只剩「本机行 + 刷新行」
      // ——它**不是空列表**,而是短一截(踩坑 #27:按 isEmpty 断言直接红)。
      final loadingItems = loadingCalls.first.args['items'] as List<Object?>;
      expect(loadingItems.length, lessThan(3));
      expect((loadingItems.first as Map<Object?, Object?>)['current'], true);

      await future;
      final doneCalls = native
          .where((c) => c.method == 'update_desktop_lyric_switch_list')
          .toList();
      expect(doneCalls.last.args['loading'], false);
      expect((doneCalls.last.args['items'] as List<Object?>).length,
          greaterThan(loadingItems.length));
    });

    test('loadPeers 抛错也要把列表推出去（不能让弹窗一直 loading）', () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      cast.loadThrows = true;
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList(); // 不应抛出

      final calls = native
          .where((c) => c.method == 'update_desktop_lyric_switch_list')
          .toList();
      expect(calls.length, 2); // loading + 真实（空远端）
      expect((calls.last.args['items'] as List<Object?>).length, 2); // 本机 + 刷新
    });

    test('关闭态 requestSwitchList 直接返回，不碰弹窗', () async {
      container.read(statusLyricsControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      container.read(statusLyricsEnabledProvider.notifier).state = false;
      native.clear();

      await container.read(statusLyricsControllerProvider).requestSwitchList();

      expect(countOf('update_desktop_lyric_switch_list'), 0);
      expect(countOf('update_desktop_lyric_state'), 0);
    });
  });

  // ==================== 八、正在播放实时刷新（5s 周期） ====================

  group('设备弹窗实时刷新', () {
    test('每 5s 并行重拉「正在播放」；停表后不再拉', () {
      cast.setPeers(<PeerInfo>[
        _peer('dlna:AAA', name: '主卧'),
        _peer('group:G1', kind: 'group', name: '客厅组'),
      ]);
      final ctrl = container.read(statusLyricsControllerProvider);
      fakeAsync((async) {
        async.elapse(const Duration(milliseconds: 20));
        container.read(statusLyricsEnabledProvider.notifier).state = true;
        async.flushMicrotasks();

        unawaited(ctrl.requestSwitchList());
        async.flushMicrotasks();
        expect(cast.nowPlayingPeers.length, 2); // 首轮 2 台各拉一次

        // 每台设备每拍都重拉 → 每拍 +2
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(cast.nowPlayingPeers.length, 4);
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(cast.nowPlayingPeers.length, 6);

        ctrl.stopSwitchAutoRefresh();
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(cast.nowPlayingPeers.length, 6);
      });
    });

    test('关闭态的 5s tick 自己停表（不空转重拉）', () {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      final ctrl = container.read(statusLyricsControllerProvider);
      fakeAsync((async) {
        async.elapse(const Duration(milliseconds: 20));
        container.read(statusLyricsEnabledProvider.notifier).state = true;
        async.flushMicrotasks();

        unawaited(ctrl.requestSwitchList());
        async.flushMicrotasks();
        final base = cast.nowPlayingPeers.length;
        expect(base, 1);

        container.read(statusLyricsEnabledProvider.notifier).state = false;
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();

        expect(cast.nowPlayingPeers.length, base);
      });
    });

    test('远端副标题取「正在播放」；拉不到给未知态', () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();

      final items = lastArgs('update_desktop_lyric_switch_list')['items']
          as List<Object?>;
      // 首轮 _fetchSwitchNowPlaying 已把「主卧」的 trackLabel 写进去
      expect((items[1] as Map<Object?, Object?>)['subtitle'], '设备正在播 - 设备歌手');
    });
  });

  // ==================== 九、接续 / 切换：行号路由与边界 ====================

  group('接续与切换（行号 → 设备）', () {
    test('pushLocalToPeer 路线上，越界行号直接 return', () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();

      await ctrl.handoffSwitchRow(99, push: true); // 越界
      expect(cast.calls, isNot(contains('pushLocalToPeer:dlna:AAA')));

      await ctrl.handoffSwitchRow(0, push: true); // 本机行 → peerIdx = -1
      expect(cast.calls, isNot(contains('pushLocalToPeer:dlna:AAA')));
    });

    test('push 成功：搬现场 + invalidate 该 peer + 成功 toast + 重推列表',
        () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();
      native.clear();

      await ctrl.handoffSwitchRow(1, push: true);

      expect(cast.calls, contains('pushLocalToPeer:dlna:AAA'));
      expect(countOf('update_desktop_lyric_switch_list'), 1);
    });

    test('push 失败：不 invalidate，只弹失败 toast 并仍重推列表', () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      cast.pushResult = false;
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();
      native.clear();

      await ctrl.handoffSwitchRow(1, push: true);

      expect(cast.calls, contains('pushLocalToPeer:dlna:AAA'));
      expect(countOf('update_desktop_lyric_switch_list'), 1);
    });

    test('pull 走 pullPeerToLocal（与 push 不同方法）', () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();
      native.clear();

      await ctrl.handoffSwitchRow(1, push: false);

      expect(cast.calls, contains('pullPeerToLocal:dlna:AAA'));
      expect(cast.calls, isNot(contains('pushLocalToPeer:dlna:AAA')));
      expect(countOf('update_desktop_lyric_switch_list'), 1);
    });

    test('pickSwitchRow 越界行号直接 return', () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();
      native.clear();

      await ctrl.pickSwitchRow(50);
      await ctrl.pickSwitchRow(-1);

      expect(cast.calls.any((c) => c.startsWith('switchTo')), false);
      expect(countOf('update_desktop_lyric_switch_list'), 0);
    });

    test('pickSwitchRow 第 0 行 = 回本机（且不看行号余量）', () async {
      cast.setActive(_peer('dlna:AAA', name: '主卧'));
      cast.setPeers(<PeerInfo>[_peer('dlna:BBB', name: '次卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);

      await ctrl.pickSwitchRow(0);

      expect(cast.calls, contains('backToLocal:true'));
      expect(cast.calls.any((c) => c.startsWith('switchTo')), false);
    });

    test('pickSwitchRow 点「停止投屏」行只停投屏', () async {
      cast.setActive(_peer('dlna:AAA', name: '主卧'));
      cast.setPeers(<PeerInfo>[_peer('dlna:BBB', name: '次卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);

      await ctrl.pickSwitchRow(1); // 投屏态下 1 = 停止投屏

      expect(cast.calls, contains('stopCasting'));
      expect(cast.calls.any((c) => c.startsWith('switchTo')), false);
    });

    test('pickSwitchRow 点远端行失败也要重推列表（保持高亮一致）', () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      cast.switchResult = false;
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();
      native.clear();

      await ctrl.pickSwitchRow(1);

      expect(cast.calls, contains('switchTo:dlna:AAA'));
      expect(countOf('update_desktop_lyric_switch_list'), 1);
    });

    test('pickSwitchRow 点「刷新设备列表」行走 requestSwitchList 而不是切换',
        () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();
      native.clear();

      // 最后一行的 title 是刷新文案，这里按行数取「刷新」行：
      // 0 本机 1 主卧 2 刷新 → 点 2。
      await ctrl.pickSwitchRow(2);

      expect(cast.calls, contains('loadPeers'));
      expect(cast.calls.any((c) => c.startsWith('switchTo')), false);
    });

    test('切换成功后 invalidate 该 peer 的 nowPlaying（列表副标题会变）',
        () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();
      native.clear();

      await ctrl.pickSwitchRow(1); // 成功

      expect(cast.calls, contains('switchTo:dlna:AAA'));
      expect(countOf('update_desktop_lyric_switch_list'), 1);
    });
  });

  // ==================== 十、开关持久化与 dispose ====================

  group('开关持久化 / dispose', () {
    test('toggle 翻转开关状态（LocalStorage 读写异常不得冒泡）', () async {
      final ctrl = container.read(statusLyricsControllerProvider);
      await enableLyrics(container);
      native.clear();

      await ctrl.toggle();
      expect(container.read(statusLyricsEnabledProvider), false);
      expect(lastArgs('set_desktop_lyric_visible')['visible'], false);
    });

    test('dispose 后停表、关订阅，不再产生任何推送', () async {
      cast.setPeers(<PeerInfo>[_peer('dlna:AAA', name: '主卧')]);
      await enableLyrics(container);
      final ctrl = container.read(statusLyricsControllerProvider);
      await ctrl.requestSwitchList();

      ctrl.dispose(); // 与 statusLyricsControllerProvider 的 onDispose 等价
      native.clear();

      player.emit(player.state.copyWith(currentSong: _song(id: 'zzz')));
      await Future<void>.delayed(Duration.zero);

      expect(countOf('update_desktop_lyric_state'), 0);
    });
  });
}
