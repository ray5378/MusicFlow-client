// CI 校验：所有「按钮类」点击操作都必须经由 MusicFlowPressable 体系(自带按压缩放),
// 不得在功能/widget 代码里直接裸用 Material 原生交互控件(它们没有统一按压反馈)。
//
// 规则：lib/ 下,除 lib/core/design/ 之外的所有 .dart 文件,如果出现下列原生
// 交互控件构造调用,即视为「未落实交互反馈」并通过非零退出码让 CI 失败。
//
//   IconButton / ListTile / TextButton / OutlinedButton / ElevatedButton /
//   FilledButton / FloatingActionButton / InkWell / RawMaterialButton
//
// 排除项：lib/core/design/ 是反馈体系的"承载层"(MusicFlowPressable 等在此定义),
// 天然允许;GestureDetector 被刻意排除——它常被用于拖拽/seek/吞掉点击/背板关闭
// 等非"按钮点击"场景,这些不需要按压缩放,且本规则专注"可点击动作"按钮类控件。
//
// 运行方式(CI)：dart run tool/check_interaction_feedback.dart
// 也支持在单文件行尾加 // echo-check-ignore 以显式豁免某一行(应尽量避免)。
import 'dart:io';

const _primitivePattern = r'IconButton|ListTile|TextButton|OutlinedButton|'
    'ElevatedButton|FilledButton|FloatingActionButton|InkWell|RawMaterialButton';
final _regex = RegExp(r'\b(?:' + _primitivePattern + r')\(');

final Directory _repoRoot = Directory(
  File.fromUri(Uri.file(Platform.script.toFilePath())).parent.parent.path,
);

bool _isUnderDesign(String path) =>
    path.replaceAll('\\', '/').contains('/core/design/');

void main() {
  final libDir = Directory('${_repoRoot.absolute.path}/lib');
  if (!libDir.existsSync()) {
    stderr.writeln('check_interaction_feedback: 找不到 lib/ (repo=${_repoRoot.path})');
    exit(2);
  }

  final problems = <String>[];
  void visit(Directory dir) {
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is Directory) {
        visit(entity);
      } else if (entity is File &&
          entity.path.endsWith('.dart') &&
          !_isUnderDesign(entity.path)) {
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final trimmed = lines[i].replaceAll(RegExp(r'\s+'), ' ');
          if (_regex.hasMatch(lines[i]) &&
              !trimmed.contains('// echo-check-ignore')) {
            problems.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
    }
  }

  visit(libDir);

  if (problems.isEmpty) {
    stdout.writeln('OK: 功能代码未出现裸原生交互控件,点击操作均已接入按压反馈。');
    exit(0);
  }

  stdout.writeln(
    'FAIL: 发现 ${problems.length} 处绕过 MusicFlowPressable 的裸原生交互控件'
    '(缺少统一按压缩放反馈):',
  );
  for (final p in problems) {
    stdout.writeln('  $p');
  }
  stdout.writeln('');
  stdout.writeln(
    '请改用 MusicFlowPressable / MusicFlowButton / MusicFlowIconButton(自带按压缩放动效),'
    '或自建反馈承载组件并放入 lib/core/design/components/。',
  );
  exit(1);
}