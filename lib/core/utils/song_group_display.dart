/// 同曲多源组的客户端展示辅助(对齐 Web 前端 displayRows 语义)。
///
/// 折叠策略:稀疏数组(WindowedPaginatedList.slots)渲染时,同组内「首个出现」
/// 的成员行显示为合并主行(渲染 `playbackSource` = sources[0],local 优先),
/// 其余成员行渲染为零高度(视觉折叠),列表索引/滚动/分页保持不变。
/// 未加载槽位(null)按「未出现」处理——同组行通常同页(后端排序稳定),跨
/// 未加载槽的组会暂时显示重复,属可接受的窗口化边界。
library;

import '../../data/models/song.dart';

/// 该槽位是否应折叠隐藏(其同组首个成员在更小索引处已出现)。
bool isCollapsedGroupSlot(
  List<Song?> slots,
  int index, {
  required String? Function(Song) groupKeyOf,
}) {
  final self = slots[index];
  if (self == null) return false;
  final gid = groupKeyOf(self);
  if (gid == null || gid.isEmpty) return false;
  for (var i = 0; i < index; i++) {
    final s = slots[i];
    if (s != null && groupKeyOf(s) == gid) return true;
  }
  return false;
}

/// 歌曲 → 组标识(groupId 为空串/缺失时返回 null,不参与折叠)。
String? songGroupIdOf(Song song) {
  final gid = song.groupId?.trim();
  return (gid == null || gid.isEmpty) ? null : gid;
}

/// 组内成员数(含自身;无 sources 返回 1)。用于主行「本地 +N」徽标。
int groupMemberCount(Song song) {
  final s = song.sources;
  return (s != null && s.isNotEmpty) ? s.length : 1;
}

/// 来源徽标文本:多源组主行显示「本地 +N」(sources[0].type 为核心源)。
/// 单源行返回 null(不显示徽标)。
String? groupSourceBadge(Song song) {
  final s = song.sources;
  if (s == null || s.length < 2) return null;
  final mainType = s.first.type ?? 'local';
  final label = switch (mainType) {
    'local' => '本地',
    'webdav' => 'WebDAV',
    'web' => '在线',
    _ => mainType,
  };
  return '$label +${s.length - 1}';
}
