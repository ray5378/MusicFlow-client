import 'package:musicflow_client/data/sources/study_api.dart';

/// 学习歌单文件夹的纯字符串工具。
///
/// 服务端把文件夹存成 `a/b` 形式的**完整路径**（见 `study/playlist-folders`
/// 接口），文件夹本身没有实体，层级只存在于路径里。首页的「学习歌单」tab 与
/// 「进入文件夹」页都基于这里的规则计算，避免两处各算一套、结果不一致。
///
/// 只做字符串运算，不碰 UI / 网络，便于单测。

/// 逐级补全父目录并按自然序排好。
///
/// 输入可能是零散路径（如只有 `课程/高数`），补全后父目录 `课程` 也会出现在
/// 结果里 —— 这样「只有子目录、没有直属歌单」的父目录也能显示出来。
List<String> buildStudyFolderPaths(Iterable<String> raw) {
  final set = <String>{};
  for (final item in raw) {
    final path = item.trim();
    if (path.isEmpty) continue;
    final parts = <String>[
      for (final seg in path.split('/'))
        if (seg.trim().isNotEmpty) seg.trim(),
    ];
    for (var i = 1; i <= parts.length; i++) {
      set.add(parts.take(i).join('/'));
    }
  }
  return set.toList()..sort(compareStudyNames);
}

/// 根层文件夹（路径里不含 `/` 的那一段）。
List<String> rootStudyFolders(Iterable<String> allPaths) => <String>[
  for (final path in allPaths)
    if (path.isNotEmpty && !path.contains('/')) path,
];

/// [parent] 下的**直接**子文件夹（只取一层，不含孙子目录）。
///
/// [parent] 传空串表示根层，等价于 [rootStudyFolders]。
List<String> studyChildFolders(Iterable<String> allPaths, String parent) {
  final prefix = parent.isEmpty ? '' : '$parent/';
  final result = <String>[];
  for (final path in allPaths) {
    if (path.isEmpty || path == parent) continue;
    if (prefix.isNotEmpty && !path.startsWith(prefix)) continue;
    // 去掉父前缀后仍含 `/` 的说明是孙子目录，本层不列。
    if (path.substring(prefix.length).contains('/')) continue;
    result.add(path);
  }
  return result..sort(compareStudyNames);
}

/// 路径最后一段，用作行标题（`课程/高数` → `高数`）。
String studyFolderLabel(String path) {
  final i = path.lastIndexOf('/');
  return i >= 0 ? path.substring(i + 1) : path;
}
