import 'package:musicflow_client/data/models/peer.dart' show castQueueItemToSong;
import 'package:musicflow_client/data/models/song.dart';

/// 桌面歌词弹窗(播放队列/切换播放器)的纯数据组拼。
///
/// 原生 Win32 层只画字符串:这里负责把三种播放链路(后端投屏 / DLNA 直投 /
/// 本机)的队列与设备列表组拼成单行显示文本 + 回传标识,逻辑纯函数、
/// 有独立单测锁定(test/providers/media/desktop_lyric_popup_test.dart)。

/// 队列单行显示文本:歌名 — 歌手(歌手为空则只有歌名)。
String desktopLyricSongRow(Song song) {
  final artist = song.artist?.trim() ?? '';
  return artist.isEmpty ? song.title : '${song.title} — $artist';
}

/// 播放队列弹窗数据:items 为已组好的显示文本,index 为当前曲下标。
class DesktopLyricQueueData {
  const DesktopLyricQueueData({required this.items, required this.index});

  final List<String> items;
  final int index;
}

/// 按当前播放链路组拼队列弹窗数据(与右侧队列面板同一优先级):
/// - 投屏链路 A(后端权威):castQueue/castIndex;
/// - DLNA 直投链路 B:playerProvider 队列 + dlnaIndex;
/// - 本机:playerProvider 队列 + localIndex。
DesktopLyricQueueData composeDesktopLyricQueue({
  required bool castActive,
  required List<Map<String, dynamic>> castQueue,
  required int castIndex,
  required List<Song> localQueue,
  required int localIndex,
  required bool dlnaCasting,
  required int dlnaIndex,
}) {
  if (castActive) {
    return DesktopLyricQueueData(
      items: castQueue
          .map((it) => desktopLyricSongRow(castQueueItemToSong(it)))
          .toList(),
      index: castIndex,
    );
  }
  return DesktopLyricQueueData(
    items: localQueue.map(desktopLyricSongRow).toList(),
    index: dlnaCasting ? dlnaIndex : localIndex,
  );
}

// ==================== 「切换播放器」弹窗 ====================

/// 「切换播放器」弹窗的一行:设备名 + 状态副标题 + 是否当前控制目标。
///
/// 与 MINI 播放条的小弹窗同构(本机行在最前,远端设备按可用性排列),
/// 原生歌词窗按这个结构画:徽章 + 设备名 + 状态副标题 + 两支接续箭头。
///
/// [badge] 为行内设备类型小标签(本机行空串;DLNA/群组等),
/// [canPull]/[canPush] 与 MINI 弹窗 `PeerCastRow` 同语义:
/// 前者=该设备有可接回的现场(↓),后者=本机有可推过去的现场(↑)。
///
/// [handoff] 决定**画不画**那两支箭头,与 canPull/canPush 是两件事:
/// MINI 弹窗的设备行**永远**有两支箭头,没「现场」可搬只是置灰。
/// 早期版本用 `canPull || canPush` 兼作显示条件,结果两支都不可用时整块
/// 箭头直接消失——用户看到的就是「歌词窗比 MINI 少了功能」(2026-09-10)。
/// 只有远端设备行 handoff=true;本机行与「停止投屏」行没有接续语义。
class DesktopLyricSwitchRow {
  const DesktopLyricSwitchRow({
    required this.title,
    required this.subtitle,
    required this.current,
    this.badge = '',
    this.canPull = false,
    this.canPush = false,
    this.handoff = false,
    this.isRefresh = false,
    this.icon = 0,
  });

  final String title;
  final String subtitle;
  final bool current;
  final String badge;
  final bool canPull;
  final bool canPush;
  final bool handoff;

  /// 「刷新设备列表」行(对齐 MINI 弹窗底部的 refresh 按钮):点击后由
  /// Dart 重新拉取设备列表,不参与切换/接续,也没有徽章与箭头。
  final bool isRefresh;

  /// 行首图标(与 MINI 弹窗 PeerCastRow/MusicFlowActionRow 同款):
  /// 0=无(原生画小圆点兜底) 1=耳机(本机) 2=基站(DLNA 设备)
  /// 3=人群(群组) 4=刷新(刷新行)。
  final int icon;

  /// 传给原生层的 map 形式(MethodChannel 只认基本类型)。
  Map<String, Object> toChannelMap() => <String, Object>{
    'title': title,
    'subtitle': subtitle,
    'current': current,
    'badge': badge,
    'canPull': canPull,
    'canPush': canPush,
    'handoff': handoff,
    'isRefresh': isRefresh,
    'icon': icon,
  };
}

/// 组拼桌面歌词「切换播放器」弹窗数据(纯函数,带单测)。
///
/// 顺序与 MINI 播放条小弹窗一致:**本机行永远在最前**,其后是本机不再
/// 作为控制目标时才会出现的「停止投屏」行,再往后是可用远端设备。
/// [localSubtitle] 由调用方按当前投屏状态给出(投屏中/本机播放/离线)。
/// [remotePeers] 只包含 **available** 的远端设备(离线设备不上列表,与
/// MINI 小弹窗同一取舍)。
List<DesktopLyricSwitchRow> composeDesktopLyricSwitchList({
  required String localTitle,
  required String localSubtitle,
  required bool localIsCurrent,
  String? stopCastTitle,
  String? stopCastSubtitle,
  String? refreshTitle,
  List<
    ({
      String name,
      String subtitle,
      String kind,
      bool current,
      String badge,
      bool canPull,
      bool canPush,
    })
  >
  remotePeers = const [],
}) {
  final rows = <DesktopLyricSwitchRow>[
    DesktopLyricSwitchRow(
      title: localTitle,
      subtitle: localSubtitle,
      current: localIsCurrent,
      // 本机行:耳机图标(与 MINI 弹窗 MusicFlowActionRow 同款)。
      icon: 1,
    ),
  ];
  if (!localIsCurrent && stopCastTitle != null) {
    rows.add(
      DesktopLyricSwitchRow(
        title: stopCastTitle,
        subtitle: stopCastSubtitle ?? '',
        current: false,
      ),
    );
  }
  for (final peer in remotePeers) {
    rows.add(
      DesktopLyricSwitchRow(
        title: peer.name,
        subtitle: peer.subtitle,
        current: peer.current,
        badge: peer.badge,
        canPull: peer.canPull,
        canPush: peer.canPush,
        // 远端设备行恒有两支接续箭头(不可用时置灰,与 MINI 弹窗一致)。
        handoff: true,
        // 设备行图标与 MINI 的 PeerCastRow 同款:群组=人群,其余=基站。
        icon: peer.kind == 'group' ? 3 : 2,
      ),
    );
  }
  // 尾部「刷新设备列表」行(对齐 MINI 弹窗底部的 refresh 按钮)。
  if (refreshTitle != null) {
    rows.add(
      DesktopLyricSwitchRow(
        title: refreshTitle,
        subtitle: '',
        current: false,
        isRefresh: true,
        icon: 4,
      ),
    );
  }
  return rows;
}

/// 弹窗**行号** → 远端设备下标;落在「本机 / 停止投屏」行或越界返回 -1。
///
/// 行序由 [composeDesktopLyricSwitchList] 固定:0 = 本机,(本机不是当前
/// 控制目标时 1 = 停止投屏),其后依次是远端设备。原生层回传的永远是
/// **行号**(switch_pick:N / switch_pull:N / switch_push:N),必须经这个
/// 纯函数换算成设备下标 —— 之前「切控制目标」和「搬现场」两处各写一遍
/// `- (hasStopRow ? 2 : 1)`,迟早写歪成点 ↓ 搬到隔壁设备(2026-09-10
/// 补接续箭头时抽出,两边共用同一套行序)。
int desktopLyricPeerIndexFromRow(int row, {required bool hasStopCastRow}) {
  final idx = row - (hasStopCastRow ? 2 : 1);
  return idx < 0 ? -1 : idx;
}
