import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/data/models/offline_cache_size.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';

/// 离线缓存设置（开关 + 容量档位），持久化并同步到缓存管理器。
final offlineCacheSettingsProvider =
    StateNotifierProvider<OfflineCacheSettingsNotifier, OfflineCacheSettings>(
      (ref) => OfflineCacheSettingsNotifier(ref),
    );

/// 离线缓存设置快照。
class OfflineCacheSettings {
  const OfflineCacheSettings({
    required this.enabled,
    required this.size,
  });

  /// 关闭后不缓存任何内容（写入 no-op + 已有缓存清空）。
  final bool enabled;
  final OfflineCacheSize size;
}

class OfflineCacheSettingsNotifier extends StateNotifier<OfflineCacheSettings> {
  OfflineCacheSettingsNotifier(this._ref)
      : super(const OfflineCacheSettings(
          enabled: true,
          size: OfflineCacheSize.g2,
        )) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final enabled = await LocalStorage.getOfflineCacheEnabled();
    final size = OfflineCacheSize.fromName(
      await LocalStorage.getOfflineCacheSizeName(),
    );
    state = OfflineCacheSettings(enabled: enabled, size: size);
    await _ref.read(offlineCacheReadyProvider.future);
    final manager = _ref.read(offlineCacheManagerProvider);
    manager.setEnabled(enabled);
    if (enabled) {
      await manager.setMaxBytes(size.maxBytes);
    }
  }

  /// 选择容量档位（隐含重新开启缓存）。
  Future<void> setSize(OfflineCacheSize size) async {
    state = OfflineCacheSettings(enabled: true, size: size);
    await LocalStorage.setOfflineCacheSizeName(size.name);
    await LocalStorage.setOfflineCacheEnabled(true);
    await _ref.read(offlineCacheReadyProvider.future);
    final manager = _ref.read(offlineCacheManagerProvider);
    manager.setEnabled(true);
    await manager.setMaxBytes(size.maxBytes);
  }

  /// 关闭缓存：停止所有写入，并清空已有缓存（设置页先弹确认框再调本方法）。
  Future<void> disable() async {
    state = OfflineCacheSettings(enabled: false, size: state.size);
    await LocalStorage.setOfflineCacheEnabled(false);
    await _ref.read(offlineCacheReadyProvider.future);
    final manager = _ref.read(offlineCacheManagerProvider);
    manager.setEnabled(false);
    await manager.clearAll();
  }

  /// 重新开启缓存（沿用上次选择的容量档位）。
  Future<void> enable() => setSize(state.size);
}
