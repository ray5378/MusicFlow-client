# 更新日志 (Changelog)

本文件记录各版本的主要变更。版本号遵循语义化版本，仅在打 `vX.Y.Z` tag 时由 CI 构建并发布（产物：Android APK / Windows 安装包）。

## [5.0.19] - 2026-09-21

### 修复 —— 拖动/点击进度条问题逐一修复

- **拖一下就跳歌/停播**：reload 成功后补 `play()`，新源首包未到被拒即走失败跳歌。改为温和恢复（只记日志，真失败由停滞/0 秒卡死看门狗接力）。
- **拖动后回到开头、再犯跳歌**：新源从余数（<1s）起步，0 秒卡死看门狗误判卡在起点而重载整首。新增 15s 落位宽限（source 前进过 1500ms 提前解除）；近末尾完成同窗抑制（拖到尾段不再被切歌）。
- **拖动卡顿/转码槽打满**：同逻辑段微调先源内 seek，被拒再升级全量重拉（`_reloadStreamForSeek` 抽取复用），拖动连发不再每次 setUrl。
- **定位偏小一帧**：`onChangeEnd` 取 scrubber 同步终值，不用异步落盘的 `_dragValue`。
- tap-cancel 语义锁定为取消（滚动误触不成跳播）；换音质/元数据翻转/回退基准经核实无害，不改。

### 配套说明
- 建议与服务端 **v4.0.2** 同步升级；预览流与离线播放不受本次改动影响。

### 构建信息
- Android: `MusicFlow-v5019-android.apk`
- Windows: `MusicFlow-v5019-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

## [5.0.18] - 2026-09-21

### 修复
- 直投 DLNA 设备的传输状态**读失败不再误判「放完」**：`SoapControl.getTransportInfo` 失败时返回的 `UNKNOWN` 此前与真 `STOPPED` 走同一条判定分支，配合「时长未知即豁免曲末校验」的放宽，**一次 SOAP 读失败就会在时长未知的曲目上演成「放完了 → 推下一首」**（曲中段误切）。现在 15s 宽限窗口内沿用最近一次成功读数，超出窗口仍读不到才认输
- `_restartPlaybackClock` 一并把状态记忆复位为 `PLAYING`：与同处合成的「新曲刚开播」`_currentStatus` 保持一致，否则上一曲末尾的 `STOPPED` 会被新曲的首次读失败沿用成「设备已停」，而 `prevState` 是合成的 `PLAYING` —— 两者矛盾会直接推走新曲

### 配套说明
- 15s 窗口与服务端 `dlna/control.ts` 的 `TRANSPORT_STATE_CACHE_MS` 同口径；建议与服务端 **v4.0.1** 同步升级
- 预览流与离线播放不受本次改动影响

### 构建信息
- Android: `MusicFlow-v5018-android.apk`
- Windows: `MusicFlow-v5018-windows-setup.exe`（安装版，安装时可勾选开始菜单 / 桌面快捷方式）

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
