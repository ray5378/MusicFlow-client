import '../../data/models/song.dart';

/// 无损 / Hi-Res 后缀集合（小写比较）。
const Set<String> _losslessSuffixes = <String>{
  'flac',
  'ape',
  'wav',
  'alac',
  'dsf',
  'dff',
  'wv',
  'tak',
  'tta',
  'aiff',
  'aif',
};

/// 音质档位标签：对齐主项目前端与参考稿（Hi-Res / Lossless / HQ / SQ / LQ）。
///
/// 字段缺失时按能拿到的信息降级判定，全部缺失返回 null（由调用方隐藏该段）。
String? songQualityLabel(Song song) {
  final bitDepth = song.bitDepth ?? 0;
  final samplingRate = song.samplingRate ?? 0;
  if (bitDepth >= 24 || samplingRate >= 88200) return 'Hi-Res';

  final suffix = song.suffix?.trim().toLowerCase() ?? '';
  if (_losslessSuffixes.contains(suffix)) return 'Lossless';

  final bitRate = song.bitRate ?? 0;
  if (bitRate >= 320) return 'HQ';
  if (bitRate >= 128) return 'SQ';
  if (bitRate > 0 || suffix.isNotEmpty) return 'LQ';
  return null;
}

/// 文件大小：对齐参考稿 `68.37M` 的两位小数写法。
String? songFileSizeLabel(Song song) {
  final size = song.size;
  if (size == null || size <= 0) return null;
  const mb = 1024 * 1024;
  const gb = 1024 * mb;
  if (size >= gb) return '${(size / gb).toStringAsFixed(2)}G';
  if (size >= mb) return '${(size / mb).toStringAsFixed(2)}M';
  if (size >= 1024) return '${(size / 1024).toStringAsFixed(0)}K';
  return '$size B';
}

/// 歌曲刮削标签分段：`音质 · 码率 · 格式 · 大小 · 时长`。
///
/// 歌手不在这里——随机歌曲信息区改为 3 行（歌名 / 歌手 / 本标签行），
/// 由行组件单独渲染歌手。缺失字段自动跳过（对齐「没有要自动隐藏标签」），
/// 时长固定放末尾。
List<String?> songMetadataParts(Song song) {
  final parts = <String?>[];

  final quality = songQualityLabel(song);
  if (quality != null) parts.add(quality);

  final bitRate = song.bitRate;
  if (bitRate != null && bitRate > 0) parts.add('${bitRate}kbps');

  final suffix = song.suffix?.trim();
  if (suffix != null && suffix.isNotEmpty) parts.add(suffix.toUpperCase());

  final sizeLabel = songFileSizeLabel(song);
  if (sizeLabel != null) parts.add(sizeLabel);

  parts.add(song.durationString);
  return parts;
}
