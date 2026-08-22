# MusicFlow 客户端（全新实现）

对标「箭头音乐」Android / Windows 双端，直连 [MusicFlow 主项目](../) 后端。
开发契约与接口映射见 [`../DEV_PLAN.md`](../DEV_PLAN.md)（以 DEV_PLAN 为准）。

## 快速开始

```bash
cd app
flutter pub get
flutter run                 # 连接的设备/模拟器
flutter build apk --release # Android
flutter build windows       # Windows（需 Windows 机器）
```

首次启动在登录页填写 MusicFlow 服务端地址（如 `http://192.168.1.10:46400`）、
用户名与密码即可；凭据仅保存在本机 `shared_preferences`。

## 功能范围（M1–M4 已落地）

- 登录（OpenSubsonic token/salt 鉴权）
- 首页：分类入口 / 随机歌曲 / 最近更新的歌单；宽屏网格 + 左侧栏（Windows 布局）
- 曲库：歌曲 / 专辑 / 艺术家 / 歌单 / 喜爱（服务端分页 `/rest/api/v1/*`）
- 详情：专辑、艺术家、歌单；播放全部
- 搜索：**主项目聚合搜索**（歌曲/专辑/艺术家三 Tab）+ 本地曲库辅助；
  在线结果经 `/rest/stream-remote` 直接播放
- 播放器：迷你条 / 全屏黑胶；随机、单曲循环、上一首/下一首、进度拖动、桌面音量
- **切换播放器（特色）**：本机 ↔ DLNA 设备（SSDP 发现 + SOAP 控制），
  三重反馈（✓ 高亮 / 图标变色 / toast），投屏时切歌自动跟随队列

## 平台注意

- Android：已开启明文流量（局域网 http 服务必需）；SSDP 组播需 `CHANGE_WIFI_MULTICAST_STATE`
- Windows：播放后端为 `just_audio_windows`

## CI

`.github/workflows/build-app.yml` 在 push 时自动跑 analyze+test 并产出
APK 与 Windows 便携 zip 工件。
