# MusicFlow 客户端

对标「箭头音乐」Android / Windows 双端的 **MusicFlow 官方客户端**，直连
[MusicFlow 主项目](https://github.com/ray5378/MusicFlow) 后端（OpenSubsonic 兼容 +
`/rest/api/v1/*` 扩展端点）。

> 📐 开发契约、接口映射、里程碑状态见 [`DEV_PLAN.md`](DEV_PLAN.md)；
> 客户端实现细节见 [`app/README.md`](app/README.md)。

## 功能

- **首页**：分类入口 / 随机歌曲（含音质行）/ 最近更新的歌单；桌面端左侧栏 + 网格布局
- **曲库**：歌曲 / 专辑 / 艺术家 / 歌单 / 喜爱 —— 全部走服务端分页，大库不卡顿
- **搜索**：主项目**聚合搜索**（歌曲 / 专辑 / 艺术家三 Tab），在线结果可直接播放
- **播放器**：迷你条 + 全屏黑胶；随机 / 单曲循环 / 进度拖动 / 桌面音量
- 🔥 **切换播放器（特色）**：本机 ↔ DLNA 设备一键切换，三重反馈（✓ 高亮 / 图标变色 /
  toast 提示）；投屏时切歌自动跟随队列；设备离线自动回本机

## 快速开始

### 从 Release 下载（推荐）

到 [Releases](https://github.com/ray5378/MusicFlow-client/releases) 获取最新构建：

| 文件 | 平台 |
|------|------|
| `MusicFlow-vX.Y.Z-android.apk` | Android 7+ |
| `MusicFlow-vX.Y.Z-windows-portable.zip` | Windows 10+（免安装） |

### 本地构建

```bash
cd app
flutter pub get
flutter build apk --release     # Android
flutter build windows           # Windows（需 Windows 机器）
```

### 连接服务器

首次启动填入 MusicFlow 服务端地址（如 `http://192.168.1.10:46400`）、用户名与密码。
凭据仅保存在本机 `shared_preferences`，鉴权采用 Subsonic token/salt 或 API Key。

## CI / 发布

`.github/workflows/build-app.yml`：

- push 到 `main` 且改动涉及 `app/**` → 双平台 analyze + test + 构建，产物上传 Artifact
- 推送 `v*` tag → 构建完成后自动创建 GitHub Release 并附 APK 与 Windows 便携包

发版流程：

```bash
git tag v1.0.0 && git push origin v1.0.0   # CI 自动出正式包
```

## 许可证

MIT © ray
