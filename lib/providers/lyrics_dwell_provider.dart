import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/sources/local_storage.dart';

/// 歌词停靠时长 Provider（秒，默认 3）。
/// 用户手动滚动歌词后，等待该时长再恢复「跟随当前歌词自动滚动」。
final lyricsScrollDwellProvider =
    StateNotifierProvider<LyricsDwellNotifier, int>((ref) {
      return LyricsDwellNotifier();
    });

class LyricsDwellNotifier extends StateNotifier<int> {
  LyricsDwellNotifier() : super(3) {
    _load();
  }

  Future<void> _load() async {
    final seconds = await LocalStorage.getLyricsScrollDwellSeconds();
    if (mounted) state = seconds;
  }

  Future<void> setDwell(int seconds) async {
    final clamped = seconds.clamp(1, 15);
    state = clamped;
    await LocalStorage.setLyricsScrollDwellSeconds(clamped);
  }
}