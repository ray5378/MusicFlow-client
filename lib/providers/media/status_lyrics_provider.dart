import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/desktop_lyric_popup.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/effective_volume.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

/// Windows 桌面歌词浮窗开关(默认关闭)。
final statusLyricsEnabledProvider = StateProvider<bool>((ref) => false);

/// 桌面歌词播放模式字符串推导(纯函数,单测锁定):
/// shuffle → 'shuffle';单曲循环 → 'repeatOne';其余 → 'repeatAll'。
/// 与 PlayerNotifier.playbackMode 同一规则,原生层按
/// 0=shuffle / 1=repeatAll / 2=repeatOne 解释。
String deriveDesktopLyricMode({
  required bool shuffleEnabled,
  required LoopMode loopMode,
}) {
  if (shuffleEnabled) return 'shuffle';
  return loopMode == LoopMode.one ? 'repeatOne' : 'repeatAll';
}

/// cast 链路 playMode(order|one|all|shuffle) → 歌词窗模式串
/// (shuffle/repeatOne/repeatAll/order,原生层按 0=shuffle/1=repeatAll/
/// 2=repeatOne/3=order 解释)。order 单独透传:迷你条顺序播放图形是
/// 有序列表(list_ordered_2),与列表循环(repeat_2 箭头)不同,歌词窗同步区分。
/// 纯函数,带单测。
String castPlayModeToLyricMode(String playMode) {
  switch (playMode) {
    case 'shuffle':
      return 'shuffle';
    case 'one':
      return 'repeatOne';
    case 'order':
      return 'order';
    default:
      return 'repeatAll';
  }
}

/// 桌面歌词控制器:持久化开关,监听播放状态(歌名/歌手/歌词行/播放/喜欢/
/// 播放模式/音量)并把完整状态推送到桌面歌词浮窗(原生 Win32 悬浮窗,
/// 两行文本 + 悬停控制按钮)。在 MainScaffold 初始化时读取一次以激活监听。
final statusLyricsControllerProvider = Provider<StatusLyricsController>((ref) {
  final controller = StatusLyricsController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

class StatusLyricsController {
  StatusLyricsController(this._ref) {
    _enabled = _ref.read(statusLyricsEnabledProvider);
    _enabledSub = _ref.listen<bool>(
      statusLyricsEnabledProvider,
      (_, next) {
        _enabled = next;
        _syncSubscriptions();
        _apply();
      },
    );
    _syncSubscriptions();
    // 启动时恢复上次开关状态并立即应用(开启则显示浮窗并推送状态)。
    _restore();
  }

  final Ref _ref;
  bool _enabled = false;
  String? _lastPushedKey;
  ProviderSubscription<bool>? _enabledSub;
  final List<ProviderSubscription<dynamic>> _playerSubs = [];

  /// 仅在开启时订阅播放状态与歌词行,避免在关闭状态下无谓触发歌词网络拉取。
  void _syncSubscriptions() {
    if (_enabled && _playerSubs.isEmpty) {
      _playerSubs.addAll([
        _ref.listen<Song?>(
          playerProvider.select((s) => s.currentSong),
          (_, __) => _push(),
        ),
        // 播放态/音量:统一链路源(effective provider)——投屏时是设备侧
        // 状态,与迷你播放条同源;设备端/其他端改音量也实时反映到歌词窗。
        _ref.listen<bool>(
          effectiveIsPlayingProvider,
          (_, __) => _push(),
        ),
        _ref.listen<double>(
          effectiveVolumeProvider,
          (_, __) => _push(),
        ),
        // 播放模式:投屏链路是设备/后端独立的 playMode,变化也要推。
        _ref.listen(
          dlnaCastProvider.select((s) => (s.isCasting, s.playMode)),
          (_, __) => _push(),
        ),
        _ref.listen(
          castPeerControllerProvider.select(
            (s) => (s.activePeer != null, s.playMode),
          ),
          (_, __) => _push(),
        ),
        _ref.listen<bool>(
          playerProvider.select((s) => s.shuffleEnabled),
          (_, __) => _push(),
        ),
        _ref.listen<LoopMode>(
          playerProvider.select((s) => s.loopMode),
          (_, __) => _push(),
        ),
        _ref.listen<String?>(
          currentLyricLineProvider,
          (_, __) => _push(),
        ),
        // 「播放队列」弹窗:队列/当前曲/任一链路投屏状态变化时推送
        // (select 窄化,避免 500ms 进度 tick 触发无谓组拼)。
        _ref.listen<List<Song>>(
          playerProvider.select((s) => s.queue),
          (_, __) => _pushQueue(),
        ),
        _ref.listen<int>(
          playerProvider.select((s) => s.currentIndex),
          (_, __) => _pushQueue(),
        ),
        _ref.listen(
          castPeerControllerProvider.select(
            (s) => (s.activePeer, s.castQueue, s.castIndex, s.offline),
          ),
          (_, __) => _pushQueue(),
        ),
        _ref.listen(
          dlnaCastProvider.select((s) => (s.isCasting, s.currentIndex)),
          (_, __) => _pushQueue(),
        ),
      ]);
    } else if (!_enabled && _playerSubs.isNotEmpty) {
      for (final sub in _playerSubs) {
        sub.close();
      }
      _playerSubs.clear();
    }
  }

  Future<void> _restore() async {
    try {
      final enabled = await LocalStorage.getStatusLyricsEnabled();
      _ref.read(statusLyricsEnabledProvider.notifier).state = enabled;
    } catch (e) {
      Logger.warnWithTag('STATUS_LYRICS', 'restore failed', e);
    }
  }

  /// 把开关状态应用到浮窗:开启 → 显示并推送当前状态;关闭 → 隐藏。
  void _apply() {
    if (_enabled) {
      unawaited(setDesktopLyricVisible(true));
      _lastPushedKey = null;
      _lastQueueKey = null;
      _push();
      _pushQueue();
    } else {
      unawaited(setDesktopLyricVisible(false));
    }
  }

  /// 托盘菜单「显示桌面歌词」与设置页开关共用入口。
  Future<void> toggle() async {
    final next = !_enabled;
    _ref.read(statusLyricsEnabledProvider.notifier).state = next;
    try {
      await LocalStorage.setStatusLyricsEnabled(next);
    } catch (e) {
      Logger.warnWithTag('STATUS_LYRICS', 'persist failed', e);
    }
  }

  void _push() {
    if (!_enabled) return;
    final player = _ref.read(playerProvider);
    final song = player.currentSong;
    final title = song?.title ?? '';
    final artist = song?.artist?.trim() ?? '';
    final lyric = _ref.read(currentLyricLineProvider) ?? '';
    // 播放态/音量:统一链路源(直投/peer 投屏时取设备侧状态,与本机无关)。
    final playing = _ref.read(effectiveIsPlayingProvider);
    final liked = player.currentSong?.starred ?? false;
    // 播放模式:本机按 deriveDesktopLyricMode 推导(纯函数,带单测);
    // 投屏链路取设备/后端独立 playMode(对齐迷你播放条模式按钮)。
    final mode = _effectiveLyricMode(player);
    final volume = double.parse(
      _ref.read(effectiveVolumeProvider).toStringAsFixed(2),
    );
    // 歌词填充色:固定暖黄(不随封面/主题取色变化)。
    const lyricColor = 0xFFC233;
    // 去重:任何字段都没变就不推。
    final key =
        '$title|$artist|$lyric|$playing|$liked|$mode|$volume|$lyricColor';
    if (key == _lastPushedKey) return;
    _lastPushedKey = key;
    unawaited(setDesktopLyricState(
      song: title,
      artist: artist,
      lyric: lyric,
      playing: playing,
      liked: liked,
      mode: mode,
      volume: volume,
      lyricColor: lyricColor,
    ));
  }

  /// 歌词窗播放模式串:投屏链路取设备/后端 playMode(order|one|all|shuffle),
  /// 与本机 shuffle/loopMode 无关;本机沿用 deriveDesktopLyricMode。
  String _effectiveLyricMode(PlayerState player) {
    final dlna = _ref.read(dlnaCastProvider);
    if (dlna.isCasting) return castPlayModeToLyricMode(dlna.playMode);
    final cast = _ref.read(castPeerControllerProvider);
    if (cast.activePeer != null) return castPlayModeToLyricMode(cast.playMode);
    return deriveDesktopLyricMode(
      shuffleEnabled: player.shuffleEnabled,
      loopMode: player.loopMode,
    );
  }

  // ==================== 播放队列 / 切换播放器弹窗 ====================

  String? _lastQueueKey;

  /// 组拼并推送「播放队列」弹窗数据(内容没变不推)。
  void _pushQueue() {
    if (!_enabled) return;
    final player = _ref.read(playerProvider);
    final cast = _ref.read(castPeerControllerProvider);
    final dlna = _ref.read(dlnaCastProvider);
    final data = composeDesktopLyricQueue(
      castActive: cast.activePeer != null,
      castQueue: cast.castQueue,
      castIndex: cast.castIndex,
      localQueue: player.queue,
      localIndex: player.currentIndex,
      dlnaCasting: dlna.isCasting,
      dlnaIndex: dlna.currentIndex,
    );
    final key =
        '${data.index}|${data.items.length}|${data.items.join('\u0001')}';
    if (key == _lastQueueKey) return;
    _lastQueueKey = key;
    unawaited(setDesktopLyricQueue(items: data.items, index: data.index));
  }

  /// 点队列行回传:按当前链路路由(与右侧队列面板同一跳播链路)。
  Future<void> jumpToQueueIndex(int index) async {
    final cast = _ref.read(castPeerControllerProvider);
    if (cast.activePeer != null) {
      await _ref.read(castPeerControllerProvider.notifier).jumpTo(index);
      return;
    }
    if (_ref.read(dlnaCastProvider).isCasting) {
      await _ref.read(dlnaCastProvider.notifier).playAt(index);
      return;
    }
    await _ref.read(playerProvider.notifier).skipToQueueItem(index);
  }

  // ==================== 「切换播放器」弹窗(歌词窗内) ====================

  String? _lastSwitchKey;

  /// 最近一次 loadPeers 拉到的设备列表(原生歌词窗设备弹窗的数据源)。
  ///
  /// 只缓存在控制器内:设备列表是「打开弹窗时按需拉」的短生命周期数据,
  /// 没必要（也不该）塞进 castPeerController 的全局 state 里污染其它页面。
  List<PeerInfo> _switchPeers = const <PeerInfo>[];

  /// 设备弹窗展开期间的「正在播放」实时刷新:
  /// - [_switchNow] 缓存每台设备最近一次拉到的正在播放(compose 取副标题用);
  /// - [_switchRefreshTimer] 每 5s 并行重拉 + 重组重推(副标题/箭头可用性
  ///   跟随真实状态;去重 key 保证无变化不白推,原生 diff 再拦一层)。
  /// 原生层 `switch_close` 事件触发停表(弹窗收起后不再重拉)。
  /// MINI 弹窗侧不经过这里——PeerCastRow 直接 watch peerNowPlayingProvider
  /// (流式轮询,autoDispose 关弹窗自动停)。
  final Map<String, PeerNowPlaying?> _switchNow = <String, PeerNowPlaying?>{};
  Timer? _switchRefreshTimer;

  /// 停掉设备弹窗的实时刷新(原生 `switch_close` 事件 / 歌词关闭 / dispose)。
  void stopSwitchAutoRefresh() {
    _switchRefreshTimer?.cancel();
    _switchRefreshTimer = null;
  }

  /// 并行拉取全部可用设备的「正在播放」到 [_switchNow]。
  Future<void> _fetchSwitchNowPlaying() async {
    final controller = _ref.read(castPeerControllerProvider.notifier);
    final peers = _availableRemotePeers();
    if (peers.isEmpty) return;
    final results = await Future.wait(
      peers.map((p) => controller.fetchPeerNowPlaying(p.peerId)),
    );
    for (var i = 0; i < peers.length; i++) {
      _switchNow[peers[i].peerId] = results[i];
    }
  }

  /// 拉一轮正在播放并重推设备列表(弹窗收起后 [_pushSwitchList] 的去重
  /// key 与原生 diff 会拦掉无变化推送,不会空转刷屏)。
  Future<void> _refreshSwitchAndPush() async {
    if (!_enabled) return;
    await _fetchSwitchNowPlaying();
    if (!_enabled) return;
    _pushSwitchList();
  }

  void _startSwitchAutoRefresh() {
    stopSwitchAutoRefresh();
    _switchRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_enabled) {
        stopSwitchAutoRefresh();
        return;
      }
      unawaited(_refreshSwitchAndPush());
    });
  }

  /// 原生层展开设备弹窗时回调:拉取最新设备列表并推送过去。
  ///
  /// 原生层不再发「打开主窗口弹窗」的请求了——设备列表就画在歌词窗上方。
  /// 先推一份 loading 占位让弹窗立刻有内容,拉到结果再推真实列表。
  Future<void> requestSwitchList() async {
    if (!_enabled) return;
    // 先把上次缓存的设备清掉:弹窗刚展开时只显示「正在加载播放器…」,
    // 绝不能让上一次的旧列表(可能只剩本机)冒充本次结果
    // (2026-09-10 用户反馈「设备列表只有本机」,旧缓存就是元凶之一)。
    _switchPeers = const <PeerInfo>[];
    _lastSwitchKey = null; // 强制下面这次一定推(用户刚展开,要看到最新)
    _pushSwitchList(loading: true);
    try {
      final peers =
          await _ref.read(castPeerControllerProvider.notifier).loadPeers();
      _switchPeers = peers;
    } catch (e) {
      Logger.warnWithTag(
          'STATUS_LYRICS', 'load peers for lyric switch failed', e);
    }
    if (!_enabled) return;
    _lastSwitchKey = null;
    _pushSwitchList();
    // 首屏立即并行拉一轮「正在播放」并重推(不等第一个 5s tick),
    // 然后进入实时刷新循环(原生 switch_close 收表)。
    await _refreshSwitchAndPush();
    _startSwitchAutoRefresh();
  }


  /// 原生层点某行的**接续箭头**:把「现场」在本机与该设备之间搬移。
  ///
  /// [push] true = ↑ 推到该设备(pushLocalToPeer),false = ↓ 接回本机
  /// (pullPeerToLocal)。语义与 MINI 弹窗 `PeerCastRow.onHandoff` 完全一致。
  /// [index] 与 composeDesktopLyricSwitchList 的行号一一对应。
  Future<void> handoffSwitchRow(int index, {required bool push}) async {
    final cast = _ref.read(castPeerControllerProvider);
    final controller = _ref.read(castPeerControllerProvider.notifier);
    final loc = l10nNowCurrent();

    // 行号 → 远端设备(跳过恒在首行的本机、以及投屏态下的「停止投屏」行)。
    final hasStopRow = cast.activePeer != null;
    final remotePeers = _availableRemotePeers();
    final peerIdx =
        desktopLyricPeerIndexFromRow(index, hasStopCastRow: hasStopRow);
    if (peerIdx < 0 || peerIdx >= remotePeers.length) {
      return;
    }
    final peer = remotePeers[peerIdx];
    final ok = push
        ? await controller.pushLocalToPeer(peer)
        : await controller.pullPeerToLocal(peer);
    if (ok) {
      _ref.invalidate(peerNowPlayingProvider(peer.peerId));
    }
    if (ok) {
      ToastNotifier.show(
        push ? loc.player_handoff_push_success(peer.name)
             : loc.player_handoff_pull_success,
        kind: MusicFlowMessageKind.success,
      );
    } else {
      ToastNotifier.show(loc.player_handoff_failed,
          kind: MusicFlowMessageKind.error);
    }
    // 现场状态变了,重推列表让箭头可用性/高亮跟着走。
    _lastSwitchKey = null;
    _pushSwitchList();
  }

  /// 原生层选中某一行:按行号执行切换(行号与 composeDesktopLyricSwitchList
  /// 的输出一一对应)。
  Future<void> pickSwitchRow(int index) async {
    final rows = _composeSwitchRows();
    if (index < 0 || index >= rows.length) return;
    // 「刷新设备列表」行:重拉列表并重推,不做切换。
    if (rows[index].isRefresh) {
      await requestSwitchList();
      return;
    }
    final cast = _ref.read(castPeerControllerProvider);
    final controller = _ref.read(castPeerControllerProvider.notifier);
    final loc = l10nNowCurrent();

    if (index == 0) {
      // 第 0 行恒为「本机」。
      await controller.backToLocal(resumeLocal: true);
      ToastNotifier.show(loc.player_switched_local,
          kind: MusicFlowMessageKind.success);
      return;
    }
    // 「停止投屏」行(仅在本机不是当前目标时存在)。
    final hasStopRow = cast.activePeer != null;
    if (hasStopRow && index == 1) {
      await controller.stopCasting();
      ToastNotifier.show(loc.player_stopped_cast,
          kind: MusicFlowMessageKind.success);
      return;
    }
    // 其余为远端设备行:按 peerId 找回对应 peer 再切换。
    final remotePeers = _availableRemotePeers();
    final peerIdx =
        desktopLyricPeerIndexFromRow(index, hasStopCastRow: hasStopRow);
    if (peerIdx < 0 || peerIdx >= remotePeers.length) return;
    final peer = remotePeers[peerIdx];
    final ok = await controller.switchTo(peer);
    if (ok) {
      ToastNotifier.show(loc.player_remote_control(peer.name),
          kind: MusicFlowMessageKind.success);
    } else {
      ToastNotifier.show(loc.player_cast_failed(peer.name),
          kind: MusicFlowMessageKind.error);
    }
    // 切换后状态变化,重推列表让高亮跟着走。
    _lastSwitchKey = null;
    _pushSwitchList();
  }

  /// 可用的远端设备(离线不上列表,与 MINI 小弹窗同一取舍)。
  List<PeerInfo> _availableRemotePeers() {
    return _switchPeers.where((p) => !p.isLocal && p.available).toList();
  }

  /// 组拼当前设备列表(纯函数 composeDesktopLyricSwitchList 的取参壳)。
  ///
  /// badge / canPull / canPush 与 MINI 播放条小弹窗 `PeerCastRow` **同语义**:
  /// - badge = 设备类型小标签(本机行空;远端取 kindLabel:DLNA/群组…);
  /// - canPull = 该设备队列非空且正在播放(有现场可接回本机);
  /// - canPush = 本机不是投屏态、且本机队列非空(有现场可推过去)。
  /// 三者缺一会让歌词窗的设备行比主窗口少东西(2026-09-10 用户反馈)。
  List<DesktopLyricSwitchRow> _composeSwitchRows() {
    final loc = l10nNowCurrent();
    final cast = _ref.read(castPeerControllerProvider);
    final localIsCurrent = cast.activePeer == null;
    // canPush 的判据与 PeerCastRow 完全一致:本机非投屏态 + 本机队列非空。
    final localQueue = cast.activePeer == null;
    final localHasQueue = _ref.read(playerProvider).queue.isNotEmpty;
    final canPush = localQueue && localHasQueue;
    return composeDesktopLyricSwitchList(
      localTitle: loc.player_source_local_title,
      localSubtitle: localIsCurrent
          ? loc.player_source_local_desc
          : (cast.offline ? loc.player_source_offline : loc.player_source_casting),
      localIsCurrent: localIsCurrent,
      stopCastTitle: loc.player_stop_cast,
      stopCastSubtitle: cast.activePeer == null
          ? null
          : loc.player_stop_cast_subtitle(cast.activePeer!.name),
      // 尾部「刷新设备列表」行:对齐 MINI 弹窗底部的 refresh 按钮。
      refreshTitle: loc.player_refresh_players,
      remotePeers: <({
        String name,
        String subtitle,
        String kind,
        bool current,
        String badge,
        bool canPull,
        bool canPush,
      })>[
        for (final p in _availableRemotePeers())
          (
            name: p.name,
            // 副标题 = 实时正在播放(与 MINI 弹窗 PeerCastRow 同源同文案):
            // trackLabel = 「歌曲 - 歌手」;拉不到显示「加载状态/未在播放」。
            // 数据来自 [_fetchSwitchNowPlaying](弹窗期每 5s 并行重拉)。
            subtitle: () {
              final now = _switchNow[p.peerId];
              return now == null
                  ? loc.player_peer_state_unknown
                  : (now.trackLabel.isEmpty
                        ? loc.player_peer_not_playing
                        : now.trackLabel);
            }(),
            kind: p.kind,
            current: cast.activePeer?.peerId == p.peerId,
            badge: p.kindLabel,
            // 该设备有可接回的现场:队列非空 + 正在播放
            // (与 PeerCastRow 的 canPull 同判据)。
            canPull: p.queueActive && p.queueTotal > 0,
            canPush: canPush,
          ),
      ],
    );
  }

  /// 推送设备列表(内容没变不推,避免无谓跨端调用)。
  void _pushSwitchList({bool loading = false}) {
    if (!_enabled) return;
    final rows = _composeSwitchRows();
    // 去重 key 必须覆盖**所有**下发字段——漏掉 badge/canPull/canPush/handoff
    // 会导致「设备列表拿到了但箭头/徽章状态不更新」(字段变了却判定为没变)。
    final key =
        '$loading|${rows.map((r) => '${r.title}\u0002${r.subtitle}\u0002'
            '${r.current}\u0002${r.badge}\u0002${r.canPull}\u0002'
            '${r.canPush}\u0002${r.handoff}\u0002${r.isRefresh}\u0002'
            '${r.icon}').join('\u0001')}';
    if (key == _lastSwitchKey) {
      return;
    }
    _lastSwitchKey = key;
    unawaited(
      setDesktopLyricSwitchList(
        items: rows.map((r) => r.toChannelMap()).toList(),
        loading: loading,
      ).then((_) {
      }).catchError((Object e) {
      }),
    );
  }

  void dispose() {
    stopSwitchAutoRefresh();
    _enabledSub?.close();
    for (final sub in _playerSubs) {
      sub.close();
    }
  }
}
