import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';

/// 首页分区用户布局（顺序 + 显隐），客户端自治覆盖服务端清单。
///
/// 启动时从 SharedPreferences 读取（损坏回落 [HomeSectionLayout.empty]，
/// 等价完全遵循服务端清单）；编辑页保存后即时更新 state 并落盘。
/// keepAlive：首页与编辑页必须共享同一份状态，编辑保存后首页立即生效。
class HomeSectionLayoutNotifier extends AsyncNotifier<HomeSectionLayout> {
  @override
  Future<HomeSectionLayout> build() async {
    final layout = await LocalStorage.getHomeSectionLayout();
    if (layout != null && !layout.isEmpty) {
      return layout;
    }
    return HomeSectionLayout.empty;
  }

  /// 保存布局：先更新内存（UI 立即生效），再落盘。
  /// 命名 save 而非 update：Riverpod AsyncNotifier 自带 update(fUTURE 回调)
  /// 签名，覆写会撞 invalid_override。
  Future<void> save(HomeSectionLayout layout) async {
    state = AsyncData(layout);
    try {
      await LocalStorage.saveHomeSectionLayout(layout);
    } catch (e) {
      Logger.warnWithTag('HOME_LAYOUT', 'home section layout save failed', e);
    }
  }
}

final homeSectionLayoutProvider =
    AsyncNotifierProvider<HomeSectionLayoutNotifier, HomeSectionLayout>(
  HomeSectionLayoutNotifier.new,
);
