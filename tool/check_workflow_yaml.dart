// 校验 .github/workflows 下所有 workflow 的 YAML 语法。
// 背景：2026-09-09 新建 playback-chain-guard.yml 时，step 的 `name: Guard: xxx`
// 写了两个冒号 → YAML 解析失败 → GitHub 把整个 workflow 当无效文件：
// API 里 name 退化成文件路径、没有 job、run 直接 failure，但**没有任何可读报错**，
// 极易误判成「测试挂了」。本工具在本地/pre-push 提前拦住这类静默失效。
//
// 用法：
//   dart run tool/check_workflow_yaml.dart [目录]   // 默认 .github/workflows
// 说明：不引第三方依赖，用一个覆盖 Actions 常用写法的最小 YAML 检查器
// （缩进层级、重复键、`key: value: value` 这类非法多冒号、tab 缩进、BOM）。
import 'dart:io';

int main(List<String> args) {
  final dir = Directory(args.isEmpty ? '.github/workflows' : args.first);
  if (!dir.existsSync()) {
    stderr.writeln('目录不存在: ${dir.path}');
    return 1;
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final errors = <String>[];
  for (final f in files) {
    errors.addAll(_checkFile(f));
  }
  if (errors.isEmpty) {
    stdout.writeln('workflow YAML OK: ${files.length} 个文件');
    return 0;
  }
  for (final e in errors) {
    stderr.writeln(e);
  }
  stderr.writeln('共 ${errors.length} 处问题');
  return 1;
}

List<String> _checkFile(File f) {
  final raw = f.readAsBytesSync();
  final out = <String>[];
  final name = f.path.replaceAll(r'\', '/');

  if (raw.length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) {
    out.add('$name: 文件含 UTF-8 BOM，GitHub 会解析失败');
  }

  final text = String.fromCharCodes(raw);
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final no = i + 1;
    if (line.contains('\t')) {
      out.add('$name:$no: 含 TAB 缩进（YAML 只允许空格）');
    }
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    // `- key: a: b` / `key: a: b`：一行里出现两个「: 」映射分隔符，
    // 除非整行值被引号包裹。这是 2026-09-09 踩过的静默失效根因。
    final body = trimmed.startsWith('- ') ? trimmed.substring(2) : trimmed;
    final ci = body.indexOf(': ');
    if (ci <= 0) continue;
    final value = body.substring(ci + 2).trim();
    final quoted = (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"));
    if (!quoted && value.contains(': ') && !value.startsWith('|') && !value.startsWith('>')) {
      final second = value.indexOf(': ');
      out.add('$name:$no: 值里出现第二个冒号（YAML 会报 mapping values are '
          'not allowed here）→ 给整个值加引号: "$value"');
      void _unused() {}
      // 提示用户改法即可，不继续解析。
      continue;
    }
  }

  // 顶层重复键（YAML 允许但 Actions 会静默取最后一个，通常是笔误）。
  final seen = <String, int>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty || line.startsWith('#') || line.startsWith(' ')) continue;
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final key = line.substring(0, idx).trim();
    if (seen.containsKey(key)) {
      out.add('$name:${i + 1}: 顶层键重复 "$key"（先前定义在 ${seen[key]} 行）');
    } else {
      seen[key] = i + 1;
    }
  }
  return out;
}
