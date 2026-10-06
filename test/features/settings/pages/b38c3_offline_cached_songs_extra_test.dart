// b38c3 —— Route C 补测：features/settings/pages/offline_cached_songs_page.dart 剩余缺口。
//   * 89：_formatBytes 的 KB 分支（bytes < 1024*1024）。
//   * 94：_formatBytes 的 GB 分支（bytes >= 1024*1024*1024）。
//
// 手法：用子类覆写 `cachedSongs` getter，构造任意 size 的缓存列表；
// offlineCacheReadyProvider 直接返回完成，避免真读磁盘。字幕里会带上格式化后的容量文本。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/settings/pages/offline_cached_songs_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

/// 覆写 cachedSongs，免去真实磁盘索引。
class _FakeCache extends OfflineCacheManager {
  _FakeCache(this._songs);

  final List<CachedSongInfo> _songs;

  @override
  List<CachedSongInfo> get cachedSongs => _songs;
}

Widget _wrap(OfflineCacheManager cache) {
  return ProviderScope(
    overrides: <Override>[
      offlineCacheManagerProvider.overrideWithValue(cache),
      offlineCacheReadyProvider.overrideWith((ref) async {}),
      playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      home: const OfflineCachedSongsPage(),
    ),
  );
}

CachedSongInfo _cached(String id, String title, int size) => CachedSongInfo(
      songId: id,
      title: title,
      artist: '歌手',
      size: size,
    );

void main() {
  testWidgets('已缓存音乐：小体积 → 容量显示为 KB（89）', (tester) async {
    // 2 * 1024 = 2 KB（< 1 MiB）。
    final cache = _FakeCache(<CachedSongInfo>[_cached('s1', '晨光曲', 2048)]);
    await tester.pumpWidget(_wrap(cache));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('KB'), findsWidgets,
        reason: '_formatBytes 走 KB 分支');
    expect(find.textContaining('GB'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已缓存音乐：超大体积 → 容量显示为 GB（94）', (tester) async {
    // 2 GiB。
    final cache = _FakeCache(
      <CachedSongInfo>[_cached('s2', '晚风曲', 2 * 1024 * 1024 * 1024)],
    );
    await tester.pumpWidget(_wrap(cache));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('GB'), findsWidgets,
        reason: '_formatBytes 走 GB 分支');
    expect(tester.takeException(), isNull);
  });
}
