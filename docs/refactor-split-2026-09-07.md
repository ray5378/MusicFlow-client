# 大文件拆分与结构优化分析（2026-09-07）

基线：v4.3.15（全量测试 525 通过 / 0 失败）。方法：3 路并行子代理结构分析 + 人工抽查行号。

## 现状

全库 241 个 Dart 文件约 6.2 万行，13 个文件超 800 行。前 13 名：

| 文件 | 行数 | 类型 | 拆分价值 |
|---|---|---|---|
| providers/player/player_provider.dart | 3824 | 单 Notifier 混多职责 | 高（但需 mixin 化，见下） |
| features/player/widgets/mini_player.dart | 2094 | 多 Widget 合集 | 高 |
| features/discover/pages/discover_page.dart | 1884 | 单页 + 内联区块 | 中 |
| features/player/pages/full_player_page.dart | 1782 | 单页强耦合 | 低-中 |
| features/discover/widgets/discover_media_widgets.dart | 1431 | 20 组件合集 | 高 |
| features/library/pages/playlist_detail_page.dart | 1243 | 单页 + 内联区块 | 中 |
| core/dlna/dlna_manager.dart | 1101 | 单类强状态 | 低 |
| features/discover/pages/search_page.dart | 982 | 单页 + 内联区块 | 中 |
| features/player/widgets/play_queue_sheet.dart | 929 | 已拆分良好 | 低 |
| widgets/music_flow_app_shell/music_flow_shell_navigation.dart | 907 | 三套导航合集 | 中 |
| features/settings/pages/app_settings_page.dart | 871 | 单页 4 分区 | 中 |
| providers/cast/cast_peer_provider.dart | 844 | 单 Notifier + 状态类 | 中 |
| providers/cast/dlna_provider.dart | 823 | Notifier + 自由函数 | 中 |

## 拆分建议清单（按优先级）

### P0 — 整块搬家，零签名变化，低风险（预计 4 处、净减约 900 行）

| 拆出 | 来源 → 目标 | 依据 |
|---|---|---|
| `VolumeButton`（1137-1490，含 Overlay 150 行） | mini_player.dart → `player/widgets/volume_button.dart` | 仅 full_player_page 引用 |
| `PlayerSwitcherSheet`（1762-2094） | mini_player.dart → `player/widgets/player_switcher.dart` | 引用少 |
| `SleepTimerSheet`（1594-1765） | full_player_page.dart → `player/widgets/sleep_timer_sheet.dart` | 仅内部使用 |
| `_AddToPlaylistSheet`（461-619） | song_options_sheet.dart → `player/widgets/add_to_playlist_sheet.dart` | 公开后传 hostContext/song |

### P1 — providers 层 mixin 化（player_provider 3824 → 约 1400）

拆分方式必须用 **mixin + 原 `playerProvider` 符号不动**，因为
`test/features/player/test_player_notifier.dart` 有 `implements PlayerNotifier` 桩，
`test/rendering/gpu_gating_test.dart` 是门禁——改成独立 Notifier 会砸测试。

| 拆出块（行号） | 目标 |
|---|---|
| 顶层纯函数（44-89） | `player_platform_helpers.dart` + re-export |
| 位置轮询 `_startPositionPolling`（3454-3758） | `PlayerPositionPollingMixin` |
| Crossfade（1626-1733） | `PlayerCrossfadeMixin` |
| Seek（3104-3444） | `PlayerSeekMixin` |
| 流媒体 URL/元数据（1293-1463） | `PlayerStreamUrlMixin` |
| 队列（2896-3001） | `PlayerQueueMixin` |

**勿拆**：`playSong` 核心（634-1784）与 `_init/_restore`——强耦合 state+player，拆了得不偿失。

### P2 — 页面层最大区块抽离（低风险，逐文件进行）

| 拆出 | 来源 |
|---|---|
| `RandomSongsSection`（666-1133，467 行） | discover_page.dart |
| `CategoryNavBar`（570-666） | discover_page.dart |
| `_SectionShift` RenderObject（365-510） | discover_page.dart |
| `_Local/_Network ResultsBlock`（497-841） | search_page.dart |
| `_PlaylistSelectionBar`（992-）/`_PlaylistIdentityHeader`（1068-） | playlist_detail_page.dart |

### P3 — 合集文件整分包（中风险，改多处 import，需回归）

- `discover_media_widgets.dart`（20 组件）→ 按 song/album/playlist/recommend 四包
- `music_flow_shell_navigation.dart` → compact/medium/expanded 三导航各一文件
- `app_settings_page.dart` → 库/播放外观/诊断/关于 四分区抽 `settings_sections/`
- `cast_peer_provider.dart` → 状态类抽 `cast_peer_state.dart`；`dlna_provider.dart` → 权限函数抽 `dlna_cast_permissions.dart`
- `dlna_manager.dart` → 仅 DIDL XML 纯函数（1042-1096）可安全抽出

## 明确不建议拆

- `full_player_page` 的 `_buildWide*`/`ProgressBar`（seek 守卫 + `_pageController`/`_closeToMini` 强耦合）
- `song_options_sheet` 的 actions 构建（耦合 ref/hostContext）
- `play_queue_sheet`（PlayQueueSheetView/CastQueueSheetView 已是自包含范式）
- `player_provider.playSong` 核心 / `dlna_manager` 主状态机

## 收益评估

- 纯"搬家型"拆分（P0/P1/P2）不改行为、不改外部 API，测试基线（525 全绿）直接兜底。
- 主要收益：单文件复杂度下降、编译增量化、协作冲突面变小；player_provider 从 3824 降到约 1400 行后，
  播放核心与轮询/crossfade/seek 的职责边界在文件层面可见。
- 成本：约 15-20 个新文件；mixin 化需谨慎处理 `_` 私有成员访问（mixin 与主体须同库可达）。
