// 一次性重构脚本：将 lib/providers/ 下的 provider 按域分到子目录，
// 并精确重写项目内所有指向被移动文件的 import（解析出绝对路径后判定是否命中，
// 命中则统一输出为 package:musicflow_client/... 风格，规避相对深度错配）。
// 用法：dart run tool/refactor_providers.dart
import 'dart:io';
import 'package:path/path.dart' as p;

// 分域映射：[旧路径, 新路径]（相对工作目录）
const moves = <List<String>>[
  // auth
  ['lib/providers/auth_provider.dart', 'lib/providers/auth/auth_provider.dart'],
  // api
  ['lib/providers/api_provider.dart', 'lib/providers/api/api_provider.dart'],
  ['lib/providers/music_provider.dart', 'lib/providers/api/music_provider.dart'],
  ['lib/providers/gd_music_provider.dart', 'lib/providers/api/gd_music_provider.dart'],
  ['lib/providers/fetch_with_cache_fallback.dart', 'lib/providers/api/fetch_with_cache_fallback.dart'],
  // library
  ['lib/providers/library_provider.dart', 'lib/providers/library/library_provider.dart'],
  ['lib/providers/library_stats_provider.dart', 'lib/providers/library/library_stats_provider.dart'],
  ['lib/providers/windowed_library_provider.dart', 'lib/providers/library/windowed_library_provider.dart'],
  ['lib/providers/metadata_cache_provider.dart', 'lib/providers/library/metadata_cache_provider.dart'],
  ['lib/providers/search_provider.dart', 'lib/providers/library/search_provider.dart'],
  ['lib/providers/recommend_provider.dart', 'lib/providers/library/recommend_provider.dart'],
  ['lib/providers/random_songs_push_provider.dart', 'lib/providers/library/random_songs_push_provider.dart'],
  ['lib/providers/playlist_provider.dart', 'lib/providers/library/playlist_provider.dart'],
  // player
  ['lib/providers/player_provider.dart', 'lib/providers/player/player_provider.dart'],
  ['lib/providers/crossfade_provider.dart', 'lib/providers/player/crossfade_provider.dart'],
  ['lib/providers/effective_playback_provider.dart', 'lib/providers/player/effective_playback_provider.dart'],
  ['lib/providers/frozen_playback_provider.dart', 'lib/providers/player/frozen_playback_provider.dart'],
  ['lib/providers/queue_origin_provider.dart', 'lib/providers/player/queue_origin_provider.dart'],
  ['lib/providers/sleep_timer_provider.dart', 'lib/providers/player/sleep_timer_provider.dart'],
  ['lib/providers/audio_quality_provider.dart', 'lib/providers/player/audio_quality_provider.dart'],
  // offline
  ['lib/providers/offline_provider.dart', 'lib/providers/offline/offline_provider.dart'],
  ['lib/providers/offline_cache_daemon.dart', 'lib/providers/offline/offline_cache_daemon.dart'],
  ['lib/providers/offline_cache_settings_provider.dart', 'lib/providers/offline/offline_cache_settings_provider.dart'],
  // cast
  ['lib/providers/cast_peer_provider.dart', 'lib/providers/cast/cast_peer_provider.dart'],
  ['lib/providers/dlna_provider.dart', 'lib/providers/cast/dlna_provider.dart'],
  // media
  ['lib/providers/lyrics_cover_provider.dart', 'lib/providers/media/lyrics_cover_provider.dart'],
  ['lib/providers/lyrics_dwell_provider.dart', 'lib/providers/media/lyrics_dwell_provider.dart'],
  ['lib/providers/status_lyrics_provider.dart', 'lib/providers/media/status_lyrics_provider.dart'],
  // ui
  ['lib/providers/theme_provider.dart', 'lib/providers/ui/theme_provider.dart'],
  ['lib/providers/locale_provider.dart', 'lib/providers/ui/locale_provider.dart'],
  ['lib/providers/palette_provider.dart', 'lib/providers/ui/palette_provider.dart'],
  ['lib/providers/navigation_provider.dart', 'lib/providers/ui/navigation_provider.dart'],
  ['lib/providers/app_visibility_provider.dart', 'lib/providers/ui/app_visibility_provider.dart'],
];

const kPackagePrefix = 'package:musicflow_client/';

void main() {
  final wd = Directory.current.path;

  // 建立 绝对路径(源) → 绝对路径(新) 映射
  final moveMap = <String, String>{};
  for (final m in moves) {
    final from = p.normalize(p.join(wd, m[0]));
    final to = p.normalize(p.join(wd, m[1]));
    moveMap[from] = to;
  }

  // 1) 移动文件（git 会在 status 里识别为 rename）
  for (final m in moves) {
    final from = p.join(wd, m[0]);
    final to = p.join(wd, m[1]);
    final toAbs = p.normalize(to);
    if (!File(from).existsSync()) {
      stderr.writeln('[skip-missing] $from');
      continue;
    }
    Directory(p.dirname(toAbs)).createSync(recursive: true);
    File(from).renameSync(toAbs);
    stdout.writeln('[moved] $m[0] -> $m[1]');
  }

  // 2) 扫描项目内所有 .dart
  final roots = <String>['lib', 'test', 'tool', 'integration_test']
      .map((d) => p.join(wd, d))
      .where((d) => Directory(d).existsSync())
      .toList();
  final files = <File>[];
  for (final r in roots) {
    files.addAll(_collectDartFiles(Directory(r)));
  }
  stdout.writeln('[debug] files=${files.length} moveMap=${moveMap.length}');

  // 3) 重写指向被移动文件的 import
  final importRe = RegExp(
    "^(\\s*(?:import|export)\\s+)(?:'([^']*)'|\"([^\"]*)\")",
    multiLine: true,
  );
  var rewrites = 0;
  for (final file in files) {
    final txt = file.readAsStringSync();
    final sb = StringBuffer();
    var last = 0;
    var changed = false;
    for (final m in importRe.allMatches(txt)) {
      sb.write(txt.substring(last, m.start));
      final prefix = m.group(1)!;
      final target = m.group(2) ?? m.group(3)!;
      final quote = m.group(2) != null ? "'" : '"';
      final newT = _resolve(target, p.dirname(file.path), wd, moveMap);
      sb.write(prefix);
      sb.write(quote);
      sb.write(newT ?? target);
      sb.write(quote);
      if (newT != null) {
        changed = true;
        rewrites++;
        stdout.writeln('[rewrite] ${file.path}: `$target` -> `$newT`');
      }
      last = m.end;
    }
    sb.write(txt.substring(last));
    if (changed) {
      file.writeAsStringSync(sb.toString());
    }
  }

  stdout.writeln('DONE: moved=$rewrites');

  // pass2：修正「被移动文件内部指向另一个被移动 provider」的 import。
  // 移动后文件深层变化导致这类兄弟/相对 import 被按新位置解析，域名可能错配
  //（如 music_provider → providers/api/metadata_cache_provider.dart 应为 library/）。
  // 用 basename→真实域名 映射统一校正，幂等。
  _fixCrossDomain(importRe, wd);

  // pass3：确定性纠错。以「实际物理位置 → basename 唯一」为准，把 lib 内所有
  // 指向 provider 文件的 package import 重写到规范路径 `providers/<域>/<basename>.dart`，
  // 根治历史 pass 产生的 缺 providers/ 前缀 与 providers/player/player/<x> 双重前缀。
  _fixCanonical(wd);
}

/// 建立 basename(去 .dart) → 规范相对路径 providers/<域>/<basename>.dart 的唯一映射。
Map<String, String> _buildProviderBasenameMap(String wd) {
  final map = <String, String>{};
  final base = p.join(wd, 'lib', 'providers');
  for (final e in _collectDartFiles(Directory(base))) {
    final rel = p.relative(e.path, from: p.join(wd, 'lib')).replaceAll('\\', '/');
    final bn = p.basenameWithoutExtension(e.path);
    if (map.containsKey(bn)) {
      throw StateError('basename collision: $bn ($map[$bn] vs $rel)');
    }
    map[bn] = rel;
  }
  return map;
}

/// 确定性修复：重写 lib/test/… 内所有指向 provider 的 package import 到规范路径。
void _fixCanonical(String wd) {
  final basenameMap = _buildProviderBasenameMap(wd);
  final uriRe = RegExp(
    "^(\\s*(?:import|export|part)\\s+)(?:'([^']*)'|\"([^\"]*)\")",
    multiLine: true,
  );
  final roots = <String>['lib', 'test', 'integration_test']
      .map((d) => p.join(wd, d))
      .where((d) => Directory(d).existsSync())
      .toList();
  var fixes = 0;
  for (final r in roots) {
    final files = <File>[];
    files.addAll(_collectDartFiles(Directory(r)));
    for (final file in files) {
      final txt = file.readAsStringSync();
      final sb = StringBuffer();
      var last = 0;
      var changed = false;
      for (final m in uriRe.allMatches(txt)) {
        sb.write(txt.substring(last, m.start));
        final prefix = m.group(1)!;
        final target = m.group(2) ?? m.group(3)!;
        final quote = m.group(2) != null ? "'" : '"';
        String? newT;
        if (target.startsWith(kPackagePrefix)) {
          final rel = target.substring(kPackagePrefix.length);
          final bn = p.basenameWithoutExtension(rel);
          final canonical = basenameMap[bn];
          if (canonical != null && canonical != rel) {
            newT = kPackagePrefix + canonical;
          }
        }
        sb.write(prefix);
        sb.write(quote);
        sb.write(newT ?? target);
        sb.write(quote);
        if (newT != null) {
          changed = true;
          fixes++;
          stdout.writeln('[canonical] ${p.relative(file.path, from: wd)}: `$target` -> `$newT`');
        }
        last = m.end;
      }
      sb.write(txt.substring(last));
      if (changed) {
        file.writeAsStringSync(sb.toString());
      }
    }
  }
  stdout.writeln('CANONICAL DONE: fixes=$fixes');
}

Iterable<File> _collectDartFiles(Directory dir) sync* {
  for (final e in dir.listSync(followLinks: false)) {
    if (e is Directory) {
      yield* _collectDartFiles(e);
    } else if (e is File && e.path.endsWith('.dart')) {
      yield e;
    }
  }
}

/// 若 [target] 指向被移动的 provider，返回新的 package 风格 URI；否则返回 null。
String? _resolve(
    String target,
    String fromDir,
    String wd,
    Map<String, String> moveMap,
  ) {
  String abs;
  if (target.startsWith(kPackagePrefix)) {
    final rel = target.substring(kPackagePrefix.length);
    abs = p.join(wd, 'lib', rel);
  } else if (target.startsWith('package:')) {
    return null; // 其它第三方包，不动
  } else if (target.startsWith('./') ||
      target.startsWith('../') ||
      !target.contains(':')) {
    // 无前缀（可含子目录）或 ./-../ 开头：一律相对当前文件目录解析。
    abs = p.normalize(p.join(fromDir, target));
  } else {
    return null; // dart: 等
  }
  abs = p.normalize(abs);
  final libRoot = p.normalize(p.join(wd, 'lib'));
  // 仅处理落在 lib/ 内的目标：相对 import 统一转 package 风格，
  // 根除「文件移动到更深子目录后相对深度错配」这一隐患；
  // lib 之外（第三方、Dart SDK、tool/test 内部相对）保持原样。
  if (!p.isWithin(libRoot, abs)) return null;
  final finalAbs = moveMap[abs] ?? abs;
  final relToLib = p.relative(finalAbs, from: libRoot).replaceAll('\\', '/');
  return kPackagePrefix + relToLib;
}

// basename(去 .dart) → 真实域名
const KDomainByBasename = <String, String>{
  'auth_provider': 'auth',
  'api_provider': 'api',
  'music_provider': 'api',
  'gd_music_provider': 'api',
  'fetch_with_cache_fallback': 'api',
  'library_provider': 'library',
  'library_stats_provider': 'library',
  'windowed_library_provider': 'library',
  'metadata_cache_provider': 'library',
  'search_provider': 'library',
  'recommend_provider': 'library',
  'random_songs_push_provider': 'library',
  'playlist_provider': 'library',
  'player_provider': 'player',
  'crossfade_provider': 'player',
  'effective_playback_provider': 'player',
  'frozen_playback_provider': 'player',
  'queue_origin_provider': 'player',
  'sleep_timer_provider': 'player',
  'audio_quality_provider': 'player',
  'offline_provider': 'offline',
  'offline_cache_daemon': 'offline',
  'offline_cache_settings_provider': 'offline',
  'cast_peer_provider': 'cast',
  'dlna_provider': 'cast',
  'lyrics_cover_provider': 'media',
  'lyrics_dwell_provider': 'media',
  'status_lyrics_provider': 'media',
  'theme_provider': 'ui',
  'locale_provider': 'ui',
  'palette_provider': 'ui',
  'navigation_provider': 'ui',
  'app_visibility_provider': 'ui',
};

/// 遍历所有 lib 内文件，修正 providers/<d>/<basename>.dart 中域名与真实域不符的 import。
void _fixCrossDomain(RegExp importRe, String wd) {
  final allFiles = <File>[];
  allFiles.addAll(_collectDartFiles(Directory(p.join(wd, 'lib'))));
  var fixes = 0;
  for (final file in allFiles) {
    final txt = file.readAsStringSync();
    final sb = StringBuffer();
    var last = 0;
    var changed = false;
    for (final m in importRe.allMatches(txt)) {
      sb.write(txt.substring(last, m.start));
      final prefix = m.group(1)!;
      final target = m.group(2) ?? m.group(3)!;
      final quote = m.group(2) != null ? "'" : '"';
      String? newT;
      final m2 = RegExp(
              '^${RegExp.escape(kPackagePrefix)}providers/([^/]+)/([^/]+)\\.dart\$')
          .firstMatch(target);
      if (m2 != null) {
        final dir = m2.group(1)!;
        final base = m2.group(2)!;
        final trueDomain = KDomainByBasename[base];
        if (trueDomain != null && trueDomain != dir) {
          newT = '${kPackagePrefix}providers/${trueDomain}/${base}.dart';
        }
      }
      sb.write(prefix);
      sb.write(quote);
      sb.write(newT ?? target);
      sb.write(quote);
      if (newT != null) {
        changed = true;
        fixes++;
        stdout.writeln('[fixdomain] ${file.path}: `$target` -> `$newT`');
      }
      last = m.end;
    }
    sb.write(txt.substring(last));
    if (changed) {
      file.writeAsStringSync(sb.toString());
    }
  }
  stdout.writeln('FIXDOMAIN DONE: fixes=$fixes');
}