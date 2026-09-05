import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/offline_cache_size.dart';
import '../data/sources/local_storage.dart';
import 'offline_provider.dart';

/// 离线缓存容量设置 Provider（持久化 + 同步到缓存管理器）。
final offlineCacheSettingsProvider =
    StateNotifierProvider<OfflineCacheSettingsNotifier, OfflineCacheSize>(
      (ref) => OfflineCacheSettingsNotifier(ref),
    );

class OfflineCacheSettingsNotifier extends StateNotifier<OfflineCacheSize> {
  OfflineCacheSettingsNotifier(this._ref) : super(OfflineCacheSize.g2) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final size = OfflineCacheSize.fromName(
      await LocalStorage.getOfflineCacheSizeName(),
    );
    state = size;
    await _ref.read(offlineCacheReadyProvider.future);
    await _ref.read(offlineCacheManagerProvider).setMaxBytes(size.maxBytes);
  }

  Future<void> setSize(OfflineCacheSize size) async {
    state = size;
    await LocalStorage.setOfflineCacheSizeName(size.name);
    await _ref.read(offlineCacheReadyProvider.future);
    await _ref.read(offlineCacheManagerProvider).setMaxBytes(size.maxBytes);
  }
}