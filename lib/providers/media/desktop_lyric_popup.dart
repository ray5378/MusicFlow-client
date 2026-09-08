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
