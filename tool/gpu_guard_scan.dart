// GPU 渲染门控结构扫描（CI 防线之一）。
//
// 规则：lib/ 下任何包含连续动画 `.repeat()` 的文件必须同时满足：
//   1) 引用至少一个门控标记（播放状态 / 大屏前台 / 窗口可见性 / 冻结进度 /
//      TickerMode）——保证新增动画不可能「裸奔」；
//   2) 使用 RepaintBoundary 隔离重绘区域——保证动画重绘不连带父级。
//
// 用法：dart run tool/gpu_guard_scan.dart [lib目录，默认 lib]
// 退出码：0 = 通过；1 = 存在未门控/未隔离的连续动画（CI 拦截）。
import 'dart:io';

const List<String> gateMarkers = [
  'appVisibilityProvider',
  'effectiveIsPlayingProvider',
  'frozenPositionProvider',
  'frozenLyricLineProvider',
  'TickerMode',
];

void main(List<String> args) {
  final root = args.isNotEmpty ? args.first : 'lib';
  final dir = Directory(root);
  if (!dir.existsSync()) {
    stderr.writeln('目录不存在: $root');
    exit(2);
  }

  final files = <File>[];
  void walk(Directory d) {
    for (final entry in d.listSync(followLinks: false)) {
      if (entry is Directory) {
        walk(entry);
      } else if (entry is File && entry.path.endsWith('.dart')) {
        files.add(entry);
      }
    }
  }

  walk(dir);
  files.sort((a, b) => a.path.compareTo(b.path));

  final errors = <String>[];
  var scanned = 0;
  for (final file in files) {
    final src = file.readAsStringSync();
    if (!src.contains('.repeat()')) continue;
    scanned++;

    final hasGate = gateMarkers.any(src.contains);
    if (!hasGate) {
      errors.add(
        '${file.path}: 含 .repeat() 连续动画但未引用任何门控'
        '(${gateMarkers.join(' / ')})',
      );
    }
    if (!src.contains('RepaintBoundary')) {
      errors.add('${file.path}: 含 .repeat() 连续动画但未用 RepaintBoundary 隔离');
    }
  }

  if (errors.isNotEmpty) {
    stderr.writeln('GPU 渲染门控检查失败（${errors.length} 处）:');
    for (final e in errors) {
      stderr.writeln('  - $e');
    }
    exit(1);
  }

  stdout.writeln('OK: 扫描 $scanned 个含连续动画(.repeat())的文件，全部已门控 + RepaintBoundary 隔离');
}
