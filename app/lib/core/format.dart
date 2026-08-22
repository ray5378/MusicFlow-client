/// 展示格式化工具（音质行 / 时长 / 文件大小）。
abstract final class Fmt {
  /// `03:55` / `1:02:03`。
  static String duration(num? seconds) {
    final total = (seconds ?? 0).round().clamp(0, 86399);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    return h > 0
        ? '$h:$mm:${s.toString().padLeft(2, '0')}'
        : '$mm:${s.toString().padLeft(2, '0')}';
  }

  /// `28.44M` / `812K`。
  static String sizeBytes(num? bytes) {
    final v = (bytes ?? 0).toDouble();
    if (v >= 1024 * 1024) return '${(v / 1024 / 1024).toStringAsFixed(2)}M';
    if (v >= 1024) return '${(v / 1024).round()}K';
    return '${v.round()}B';
  }

  /// 码率：`320kbps`；未知返回空。
  static String bitRate(num? kbps) =>
      kbps == null || kbps <= 0 ? '' : '${kbps.round()}kbps';

  /// 无损标记：suffix 属于无损格式时返回 Lossless，否则空。
  static String lossless(String? suffix) {
    const set = {'flac', 'wav', 'ape', 'alac', 'aiff'};
    return set.contains((suffix ?? '').toLowerCase()) ? 'Lossless' : '';
  }

  /// 首页歌曲行第三行：`Lossless • 138kbps • FLAC • 28.44M • 03:55`。
  static String qualityLine({
    String? suffix,
    num? bitRateKbps,
    num? size,
    num? durationSeconds,
  }) {
    final parts = <String>[
      if (lossless(suffix).isNotEmpty) 'Lossless',
      if (bitRate(bitRateKbps).isNotEmpty) bitRate(bitRateKbps),
      if ((suffix ?? '').isNotEmpty) suffix!.toUpperCase(),
      if (size != null && size > 0) sizeBytes(size),
      if (durationSeconds != null && durationSeconds > 0)
        duration(durationSeconds),
    ];
    return parts.join(' • ');
  }
}
