# just_audio vendored 副本(MusicFlow)

来源:pub.dev just_audio 0.9.46,原样拷贝(排除 example)。

## 为什么 vendor

服务端 v4.2.0(batch44)为网络源提供 30 分钟取流重试窗:源断网时对客户端
挂起 /rest/stream 请求不发字节,窗口内源恢复即自动出流。上游插件
`AudioPlayer.buildDataSourceFactory` 用 `DefaultHttpDataSource.Factory`
默认超时(connect/read 各 8s),服务端还在等源恢复就被 Android 端掐断,
30 分钟自愈窗口形同虚设;桌面端走 libmpv(network-timeout=0)无此问题。

## 补丁内容(唯一改动)

`android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java`
`buildDataSourceFactory`:`setConnectTimeoutMs(30_000)` +
`setReadTimeoutMs(31 * 60 * 1000)`(30min 窗口 + 余量)。

## 升级方式

换新版 just_audio 时:拷贝新版到本目录,重放上面这处补丁,
核对 `pubspec.yaml` 的 dependency_overrides 仍指向本目录。
