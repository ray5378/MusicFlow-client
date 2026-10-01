import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 首页分区注册表：客户端认识的分区 key、默认顺序、用户布局合并规则、
/// 分区显示名与编辑模式顺序构建。首页（discover_page）与编辑页共用。

/// 首页「播放控制」整体块 —— **客户端自治**分区 key。
///
/// 该块是纯客户端能力(遥控器视图),后端没有对应数据源,因此不依赖服务端
/// 清单下发:由客户端无条件注入并置顶(见 [injectClientOwnedSection] /
/// [hoistClientOwnedSection])。
/// key 落库即持久化数据,改名要做迁移,一次定死;全仓唯一定义,任何地方
/// 不许写字面量 'remote-control'。
const String kRemoteControlSectionKey = 'remote-control';

/// 分区清单加载失败/未就绪时的回落顺序(与历史首页一致,仅推荐两模块按
/// 新定位排序:「平台推荐」(本地库,local-recommend)在「插件推荐」
/// (platform-recommend)之前)。
///
/// 首位的 [kRemoteControlSectionKey] 是客户端自治分区:它同时是编辑页
/// 的顺序源(见 [buildHomeSectionEditOrder])与清单未就绪时的回落顺序,
/// 清空 layout 后冷启动该块在最前。
const List<String> kDefaultHomeSectionKeys = <String>[
  kRemoteControlSectionKey,
  'random-songs',
  'recent-playlists',
  'home-recommend',
  'local-recommend',
  'platform-recommend',
];

/// 推荐两模块定序归一:客户端首页固定「平台推荐」(local-recommend,本地库
/// 随机歌单)在「插件推荐」(platform-recommend,插件提供方)之前,无论服务端
/// 清单下发顺序如何——推荐模块重定位后两个分区是包含关系的层级展示,
/// 顺序由客户端定死,其余分区仍完全遵循服务端清单。仅当两者同时可见时生效。
List<String> normalizeRecommendSectionOrder(List<String> keys) {
  final platformIdx = keys.indexOf('platform-recommend');
  final localIdx = keys.indexOf('local-recommend');
  if (platformIdx < 0 || localIdx < platformIdx) return keys;
  final reordered = <String>[
    for (final key in keys)
      if (key != 'local-recommend') key,
  ];
  reordered.insert(reordered.indexOf('platform-recommend'), 'local-recommend');
  return reordered;
}

/// 注入客户端自治分区到 base 列表最前。**幂等**(已存在则返回原 list)。
///
/// 服务端清单无论含不含该 key,它都会出现 —— 否则「服务端清单非空且不含
/// 该 key」时本块永不渲染(该块是纯客户端能力,后端不会下发它)。
List<String> injectClientOwnedSection(List<String> baseKeys) {
  if (baseKeys.contains(kRemoteControlSectionKey)) return baseKeys;
  return <String>[kRemoteControlSectionKey, ...baseKeys];
}

/// 用户**从未排过**该 key 时强制提到最前,覆盖 [applyHomeSectionLayout] 的
/// 「未排过 → 追加尾部」语义;用户排过则原样返回,尊重用户位置。
///
/// 存量用户保护:老用户已存过一份只含旧 5 项的 order,升级后本 key 属于
/// 「未排过」→ 会被追加到**尾部**,默认置顶对存量用户静默失效。本函数
/// 专门兜这个([applyHomeSectionLayout] 本身零改动)。
List<String> hoistClientOwnedSection(
  List<String> keys,
  HomeSectionLayout layout,
) {
  if (!keys.contains(kRemoteControlSectionKey)) return keys; // 被用户隐藏
  if (layout.order.contains(kRemoteControlSectionKey)) return keys; // 用户排过
  return <String>[
    kRemoteControlSectionKey,
    ...keys.where((k) => k != kRemoteControlSectionKey),
  ];
}

/// 合并用户布局与服务端清单（客户端自治核心）：
/// 1) 顺序：用户排过序的分区按用户顺序在前；服务端清单中用户未排过
///    （新增/首次出现）的分区按服务端 sortOrder 追加尾部；
/// 2) 可见性：用户隐藏的分区直接不渲染——分区 widget 不构建，其数据
///    provider（autoDispose / 未被 watch 的 keepAlive）自然不会拉取服务端。
List<String> applyHomeSectionLayout(
  List<String> base,
  HomeSectionLayout layout,
) {
  if (layout.isEmpty) return base;
  final baseSet = base.toSet();
  // 用户排过序且当前仍存在于服务端清单的分区（清单已下线的 key 自动淘汰）。
  // 不能在 list literal 的集合 if 内引用自身变量(Dart 编译错误),用循环 append。
  final ordered = <String>[];
  for (final key in layout.order) {
    if (baseSet.contains(key) && !ordered.contains(key)) {
      ordered.add(key);
    }
  }
  // 服务端新增、用户尚未排过的分区 → 追加尾部。
  final merged = <String>[
    ...ordered,
    for (final key in base) if (!ordered.contains(key)) key,
  ];
  // 用户隐藏的分区从渲染清单剔除（不渲染 = 不拉取）。
  final hidden = layout.hidden.toSet();
  return <String>[
    for (final key in merged)
      if (!hidden.contains(key)) key,
  ];
}

/// 分区显示名（编辑页用；客户端固定认识的分区均有本地化文案）。
String homeSectionDisplayName(AppLocalizations loc, String key) {
  switch (key) {
    case kRemoteControlSectionKey:
      return loc.discover_remote_control;
    case 'random-songs':
      return loc.discover_random_songs;
    case 'recent-playlists':
      return loc.discover_recent_playlists;
    case 'home-recommend':
      return loc.discover_for_you;
    case 'local-recommend':
      return loc.discover_local_random;
    case 'platform-recommend':
      return loc.discover_platform_recommend;
    default:
      return key;
  }
}

/// 编辑模式的分区顺序（含用户隐藏的分区）：用户排过序的按用户顺序在前，
/// 用户未排过的（服务端新增/首次编辑）按客户端默认清单顺序追加。
/// 不依赖服务端清单——6 个分区是客户端固定认识的（含客户端自治的
/// 「播放控制」块），服务端清单加载失败时编辑页依然可用。
List<String> buildHomeSectionEditOrder(HomeSectionLayout layout) {
  // 不能在 list literal 的集合 if 内引用自身变量,用循环 append。
  final known = <String>[];
  for (final key in layout.order) {
    if (kDefaultHomeSectionKeys.contains(key) && !known.contains(key)) {
      known.add(key);
    }
  }
  return <String>[
    ...known,
    for (final key in kDefaultHomeSectionKeys) if (!known.contains(key)) key,
  ];
}
