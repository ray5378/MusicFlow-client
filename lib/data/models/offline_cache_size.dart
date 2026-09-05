import '../../core/l10n/localizations.dart';

/// 离线缓存总容量档位。
enum OfflineCacheSize {
  m512,
  g1,
  g2,
  g3,
  g4,
  g5,
  g6,
  g7,
  g8,
  g9,
  g10;

  /// 各档位对应的字节数。
  int get maxBytes {
    const mb = 1024 * 1024;
    const gb = 1024 * mb;
    return switch (this) {
      OfflineCacheSize.m512 => 512 * mb,
      OfflineCacheSize.g1 => gb,
      OfflineCacheSize.g2 => 2 * gb,
      OfflineCacheSize.g3 => 3 * gb,
      OfflineCacheSize.g4 => 4 * gb,
      OfflineCacheSize.g5 => 5 * gb,
      OfflineCacheSize.g6 => 6 * gb,
      OfflineCacheSize.g7 => 7 * gb,
      OfflineCacheSize.g8 => 8 * gb,
      OfflineCacheSize.g9 => 9 * gb,
      OfflineCacheSize.g10 => 10 * gb,
    };
  }

  bool get isGigabyte => this != OfflineCacheSize.m512;

  int get gigabyteCount => switch (this) {
        OfflineCacheSize.m512 => 0,
        OfflineCacheSize.g1 => 1,
        OfflineCacheSize.g2 => 2,
        OfflineCacheSize.g3 => 3,
        OfflineCacheSize.g4 => 4,
        OfflineCacheSize.g5 => 5,
        OfflineCacheSize.g6 => 6,
        OfflineCacheSize.g7 => 7,
        OfflineCacheSize.g8 => 8,
        OfflineCacheSize.g9 => 9,
        OfflineCacheSize.g10 => 10,
      };

  String get displayName {
    final loc = l10nNowCurrent();
    if (isGigabyte) {
      return '$gigabyteCount ${loc.offline_cache_unit_gb}';
    }
    return '512 ${loc.offline_cache_unit_mb}';
  }

  /// 从字符串名称解析（未命中回落默认 2G）。
  static OfflineCacheSize fromName(String? name) {
    return OfflineCacheSize.values.firstWhere(
      (e) => e.name == name,
      orElse: () => OfflineCacheSize.g2,
    );
  }

  /// 从字节数取最近的匹配档位（用于显示当前配置）。
  static OfflineCacheSize fromBytesFloor(int bytes) {
    if (bytes <= 0) return OfflineCacheSize.g2;
    var best = OfflineCacheSize.g2;
    for (final option in OfflineCacheSize.values) {
      if (option.maxBytes <= bytes) best = option;
    }
    return best;
  }
}