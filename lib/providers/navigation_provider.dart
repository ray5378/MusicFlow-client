import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shell 分支索引。
/// 「探索」分支已按对齐决策移除,仅保留音乐流一个 shell 分支;
/// libraryBranchIndex 不再作为 shell 分支存在,仅供离线重试作用域
/// (VisibleRemoteRetryScope)标识曲库类页面。
const discoverBranchIndex = 0;
const libraryBranchIndex = 2;

final currentVisibleBranchIndexProvider = StateProvider<int>(
  (ref) => discoverBranchIndex,
);
