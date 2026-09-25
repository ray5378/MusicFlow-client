import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// 同一歌单自动匹配的节流窗口(与 Web 前端一致:24 小时)。
const Duration playlistAutoMatchTtl = Duration(hours: 24);

/// 最多轮询多少轮。
const int playlistAutoMatchMaxPolls = 45;

/// 每轮轮询间隔:服务端要先抢全局批量闸(可能被全库扫描占住),不会立刻有结果,
/// 故间隔取中等值,既不空转也不把后台任务拖到没有意义的长度。
const Duration playlistAutoMatchPollInterval = Duration(seconds: 8);

final Map<String, DateTime> _lastAutoMatchAt = <String, DateTime>{};

/// 该歌单是否在 24 小时的节流窗口内已经跑过一次。
bool isPlaylistAutoMatchThrottled(String playlistId) {
  final last = _lastAutoMatchAt[playlistId];
  if (last == null) return false;
  return DateTime.now().difference(last) < playlistAutoMatchTtl;
}

/// 记录一次匹配已发起 —— 即使这一轮一首都没匹配上,也不该被同一窗口内反复重试。
void markPlaylistAutoMatch(String playlistId) {
  _lastAutoMatchAt[playlistId] = DateTime.now();
}

/// 起播歌单之后由调用方 fire-and-forget 触发的「自动匹配 + 队尾补齐」。
///
/// 服务端会把库里匹配不上的条目(门禁拦下 / 在线源下架)重新搜一遍,命中的曲目
/// 被接在当前队列尾部:已经听到了多少完全不受影响,只是接着往下不再漏。
///
/// 只返回补进队尾的曲目数(0 = 没新匹配到,或已在节流窗口内);**提示文案由调用
/// 方给 Toast** —— 慢路径不起对话框,绝不能挡着正在听的人。
Future<int> autoMatchAndAppendPlaylist(
  WidgetRef ref, {
  required String playlistId,
  required List<Song> startedSongs,
}) async {
  if (playlistId.isEmpty) return 0;
  if (isPlaylistAutoMatchThrottled(playlistId)) return 0;
  markPlaylistAutoMatch(playlistId);

  final repository = ref.read(playlistRepositoryProvider);
  if (repository == null) return 0;

  try {
    await repository.triggerPlaylistAutoMatch(playlistId);
  } catch (e) {
    Logger.warnWithTag('AUTO-MATCH', '歌单 $playlistId 触发失败: $e');
    return 0;
  }

  var latest = startedSongs;
  for (var i = 0; i < playlistAutoMatchMaxPolls; i++) {
    await Future<void>.delayed(playlistAutoMatchPollInterval);
    List<Song>? fresh;
    try {
      fresh = await repository.getAllPlaylistSongs(playlistId);
    } catch (e) {
      Logger.warnWithTag('AUTO-MATCH', '歌单 $playlistId 轮询失败: $e');
      break;
    }
    latest = fresh;
    if (_diffSongs(fresh, startedSongs).isNotEmpty) break;
  }

  final added = _diffSongs(latest, startedSongs);
  if (added.isEmpty) return 0;
  // 只动队尾:正在播的那一首与它之前的顺序一动不动。
  await ref.read(playerProvider.notifier).appendToQueue(added);
  Logger.infoWithTag('AUTO-MATCH', '歌单 $playlistId 补齐 ${added.length} 首');
  return added.length;
}

/// 相对 [base] 新出现的曲目 —— 按 **songId** 判重而不是行号:匹配入库只是在原有
/// 条目上补上 songId,条目位置不变,用行号比对会把原有曲目误判成「新增」。
List<Song> _diffSongs(List<Song> fresh, List<Song> base) {
  final seen = <String>{};
  for (final s in base) {
    if (s.id.isNotEmpty) seen.add(s.id);
  }
  return fresh.where((s) => s.id.isNotEmpty && !seen.contains(s.id)).toList();
}
