# 更新日志 (Changelog)

本文件记录各版本的主要变更。版本号遵循语义化版本，仅在打 `vX.Y.Z` tag 时由 CI 构建并发布（产物：Android APK / Windows 安装包）。

## [5.0.17] - 2026-09-21

### 新功能
- P2-3：seek 判定改为**按服务端管道化能力切换** —— `shouldUseServerTimeOffsetSeek` 新增 `serverPipelinedHttp` 开关，命中时无条件走 timeOffset 重拉（服务端 P2-1 起全通道实时流，即使格式一致也不再字节 seek，旧结论作废）

### 修复
- 修客户端 6 条 CI 编译红灯：`_serverPipelinedHttp()` 原写在 `mixin PlayerSeekInternals on PlayerNotifier` 内，`PlayerNotifier` 基类与另一个 mixin 都访问不到（Dart：mixin 成员只对混入它的类可见），下沉到 `PlayerNotifier` 基类后恢复

### 其他
- CI Flutter 版本统一到 **3.47.5**：原 `3.38.10` × 4 处 / `3.47.1` × 12 处分裂，`server-contract.yml` 还曾是浮动的 `channel: stable`（已钉死）。消除旧 Dart SDK 解析同一份 `pubspec.lock` 造成的依赖降级（characters / intl / matcher）

### 配套说明
- 管道化门槛 `kPipelineMinServerVersion = 3.0.47`：仅 MusicFlow 且版本 ≥ 门槛判 true；Navidrome / 老版本 / 未知版本一律保守 false，行为与此前一致
- 预览流（`false` 硬编码）与离线播放不受本次改动影响

### 构建信息
- Android: `MusicFlow-v5017-android.apk`
- Windows: `MusicFlow-v5017-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [4.3.43] - 2026-09-11

### 新功能
- 本机播放补齐第四种播放模式 `order`（顺序播），与 Web / 服务端对齐为 4 态：`order` / `all` / `one` / `shuffle`
- 本机在线播放改为**以服务端预探测判定为预跳过依据**：起播前先跳过服务端已判无源（短 TTL）的歌；本机只在真正播放失败时才兜底跳过

### 配套说明
- 需配合**服务端 v2.3.25** 的队列预探测功能；服务端未升级时，本机仍走原有本地兜底逻辑
- 无效源不写库、不做死歌名单，换源可救回的歌不会被永久拉黑
- Web 端的「预探测已暂停」右上角持久轻提示由服务端 v2.3.25 提供

### 构建信息
- 提交: `8d74a8323f612e28bf579a25f287bfa5fa895898`
- Android: `MusicFlow-v4343-android.apk`
- Windows: `MusicFlow-v4343-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）
