# 接续搬移主通道优先 + 4 链路坏源守卫固化

**日期**：2026-09-10
**版本**：客户端 v4.3.39 / 主仓库 v2.3.24
**commit**：fcc412d（客户端）、33029c5 + 62e9c86（主仓库）

---

## 最新：真机 + WAF 端到端验收 —— **通过**

公网入口 `https://music.cmct.fun:35378`（**Lucky WAF 开启**）实机验证：
安卓本机播「今日漫游」3251 首 → 投屏「主卧」，**三重判据全部通过**。

| 判据 | 结果 |
|---|---|
| 主通道请求体 **170 B** → `HTTP 200`，2.46 s 返回 `queued=3251` + `shuffleOrder` | ✅ |
| 对照：整队 **606.3 KB** → `403 Lucky WAF` | ✅（闸门存在且被绕过） |
| 设备队列前 50 槽 vs 歌单默认序 → **0 处不一致**（`ORDER BY position,id` 生效） | ✅ |
| `shuffleOrder` = `0..3250` 合法排列，客户端 170 B 请求体不含该数组 → 服务端产物 | ✅ |
| 槽 0 songId == 本机在播「莫忙」songId，逐字一致 | ✅ |
| 设备 `position` 稳定推进（10→13→…→31，每 3 s +3 s）→ **真实出声** | ✅ |

> ⚠️ 该设备 `state` 恒为 `STOPPED`（2017 MUZO 固件不回传 transport state），
> **判「是否在播」看 `position`，不看 `state`**。
> ⚠️ 操作顺序：**必须先本机播放，再点投屏**（切播器按钮点击点 `(959, 2052)`，主卧行 `(540, 1882)`）。

详见 `outputs/waf_e2e_verification.md`。

---

## 补记：遗留问题收口（主仓库 v2.3.24）

`resolveContentSongs('playlist')` 缺 `ORDER BY position` 的部分**早已修复**
（`c942adf`，在 `v2.3.23`，有 `contentOrder.test.ts` 行为守卫）。

但同一根因「两侧排序不同源」还有**第二个漏斗**：**Web 前端从未走过主通道** ——
`grep -rn "v1/play\"" frontend/src` 结果为空，所有投屏起播一律整队推送 →
大歌单在公网入口撞 **Lucky WAF 体积闸门**（≈300 首即 403）→ 起播失败。

**v2.3.24 修复**：`RemoteState.contentOrigin` + `startCastPlaybackMainChannelFirst`
（整份内容点播走 `/v1/play` 下发 `songId`，失败才回落整队推送）；
新增 `playContentContract.test.ts`（6 项，**payload 级断言**，5 个变异全被抓）；
CI 接入两个测试文件 + 新增静态守卫步骤。

→ 至此客户端 / Web 前端 / HA 集成**三仓全部主通道优先**。
详见 `outputs/遗留问题修复与全链路最终汇报.md`。

---

## 用户需求

> 把 4 条链路（服务端前端 / Win+安卓本机播放 / 本机直投 DLNA / 服务端推 DLNA）
> 在本地拿服务端数据跑模拟，确认**本机源无效、WebDAV 源无效、未命中歌曲、换源、
> 全部源失效切歌**下播放链路都不会卡住；确认既有专门逻辑是否还有效；用 CI 固定住。

## 一、搬移主通道优先（大歌单不再传 MB 级整队）

`pushLocalToPeer`（「本机→音箱」接续搬移）此前只做整队推送，payload 随队列规模膨胀。
改为**主通道优先**：队列源自歌单/专辑/艺术家时，只发
`POST /rest/api/v1/play {peerId,type,id,songId}`，服务端自行查库解析队列。

真机实测（`tool/verify_handoff_main_channel.py`，公网 :35378，3251 首）：

| 指标 | 主通道 `/play` | 整队 `/queue/play` |
| --- | --- | --- |
| body | **115B** | 642.3KB |
| 耗时 | **296ms** | 7986ms |
| 随队列规模 | 无关 | 线性劣化 |

→ **缩 5720×、快 27×**。来源不可解析（discover/search/other/本地队列）仍回落整队推送。

## 二、队列来源持久化（关闭重启后的静默退化）

会话恢复路径直接调 `playSong` 而不经过 `playEffectiveQueue`，重启后 `queueOrigin`
丢失 → 搬移退化回整队推送。现将会话 payload 增加 `queueOrigin` 字段并成对恢复；
写入/读取共用 `kSessionQueueOriginKey` + `readSessionQueueOrigin`，两侧不会各写各的键名。

## 三、🔴 挖出并修复一个严重漏洞（变异验证的产物）

**变异实验**：在 `_handlePlaybackError` 方法体插入 `if (true) return;`
（原 `next()` 仍在，只是变成死代码）→ 既有守卫 **4/4 全绿**！

根因：所有断言都是 `contains('next()')` 这类**字面包含**检查 —— 文本里 `next()` 还在，
但永远执行不到。用户表现为**永远卡在坏源上**，正是「播放链路卡住」的典型形态。

**修法**：断言改为**可达性**检查 —— 方法体内不得出现恒真短路；`next()` 之前的
提前 `return` 只允许含 `mounted` 守卫。两个文件双双加固并变异复验（改回即转红）。

## 四、4 条链路职责分工（不越界）

| 链路 | 「不卡死」责任方 | 本仓覆盖 |
| --- | --- | --- |
| ① 服务端 Web 前端 | 服务端仓 `playback-chain-guard.yml` | 不可见 |
| ② 本机播放 | `_handlePlaybackError → next()` | ✅ |
| ③ 本机直投 DLNA | `DlnaManager._playCurrentTrack` 预检 + 409 跳曲 | ✅ |
| ④ 服务端推 DLNA | **裁决权在服务端**，客户端只镜像 | ✅（反向钉死） |

## 五、新增测试（+13）

- `test/core/playback/source_failure_chain_test.dart`（11 项，新）
  含圈数守卫 `probeSkips >= _queue.length`（防整队全坏源无限绕圈挂死 `startCast`）、
  单曲无源短路 `_queue.length > 1 &&`、预检网络抖不误杀、链路 A 客户端禁持 `_deadSongs`。
- `test/providers/handoff_e2e_test.dart`（5 项）：真 HTTP 假服务端 + 真 ProviderContainer。
- `playback_error_guard_test.dart` +1（reachability）。
- `tool/handoff_e2e_scan.dart`（新）：钉死 E2E 脚手架契约。

## 六、CI 固化

`playback-chain-guard.yml`（阻塞型）新增两步：
- `Run source-failure chain simulation tests`
- `Guard - handoff end-to-end (real HTTP, large playlist)`

## 七、闸门确认（曾误判，已纠正）

公网入口（反代 Lucky WAF）对 `POST /queue/play` + 大批量 JSON 数组有**体积闸门**：
约 90KB（≈300 首）起即 `403 Lucky WAF` —— **反代层拒绝，不是服务端**。
→ **主通道优先是可用性要求，不是性能优化**：整队推送在公网不是慢，是**发不出去**。

> ⚠️ 中途误判记录：复测时闸门**正好被运维关闭**，见 541KB/642KB/868KB 均 200，
> 一度错误地把本结论标为「已推翻」并改了注释。经 ray 澄清后已全部恢复，
> 并在脚本/注释中加注**复测注意事项**：判定闸门看响应体是否含 `Lucky WAF`/403，
> **不能只看体积是否通过**；闸门可被临时开关。

## 八、验证基线

| 项目 | 结果 |
| --- | --- |
| 全量 `flutter test` | **622/622**（+13） |
| 守卫测试集 | 112/112 |
| `check_interaction_feedback` / `check_workflow_yaml`(9) / `gpu_guard_scan` | OK |
| `handoff_chain_scan` / `handoff_e2e_scan` | OK |
| `dart analyze lib/` | 0 error（133 条既有 info） |

---

# 安卓投大歌单失败 —— 根因修复与跨仓发版

**日期**：2026-09-10
**版本**：客户端 v4.3.37 / 主仓库后端 v2.3.22（同批发版）

---

## 一、问题

安卓客户端投「今日漫游」（数千首）失败；**Windows 同网段可以**，**小歌单也可以**。

## 二、根因：起点定位用了行号，不是身份

不在传输规模，而在 `/v1/play` 的**起点定位方式**：

| | 旧实现 | 问题 |
| --- | --- | --- |
| 参数 | `startIndex` | 客户端列表的**行号** |
| 服务端行为 | 按自己的解析顺序取第 N 首 | 两侧顺序不同源时**必然漂移** |
| 越界处理 | **静默归 0**（从头播） | 不报错 → 用户观感「点了没反应」 |

顺序为什么会不同源：
- `resolveContentSongs('playlist')` 曾缺 `ORDER BY`（rowid 序 vs 客户端 `position` 序）
- 悬空 `playlistSongs`（`songs` 行已删）被 `.filter(Boolean)` **静默丢弃** → 少一首 → 其后全部错位
- 实测：24 个真实歌单抽样，**6 个「同集异序」≈25%**；长度校验**一个都抓不到**（长度全相同）

> 「Windows 能投、安卓不能」的差异来自超时而非逻辑：主通道曾硬编码 15s，
> 大歌单服务端解析+落库+等设备（含 ~5s GENA 窗口）顶穿后误判失败 →
> 触发回落重推 2MB 整队 —— **同一件事做了两遍**。

## 三、修复：songId 身份定位（跨两仓）

```
客户端 ──POST /rest/api/v1/play {peerId, type, id, songId}──▶ 服务端
                                        │ resolveContentSongs 查库
                                        │ findIndex(it => it.songId === songId)
                                        └─▶ playFrom(设备) 投屏   ← 与排序无关
```

**主仓库 v2.3.22**
- `/v1/play` 新增 `songId`：`items.findIndex(...)` 按身份定位
- 未命中 → **404 `errors.renderer.songNotInContent`**（不再静默归 0）
- 未传 `songId` → 保留 `startIndex` 兼容路径（Web 前端 / HA 集成存量调用方）
- 回执带 `songId: items[start]?.songId`
- i18n 中英各补一条

**客户端 v4.3.37**
- `playContentOnPeer` 传 `songId`；请求体**二选一**（有 songId 就不发 startIndex，混传会让服务端误按行号取）
- **整个投后槽位校验块删除**（详见下节）
- 本地乐观镜像改 `indexWhere(e['songId'] == songId)` **按身份对齐游标**
- 新增 `contentPlayBudget(n) = queueTransferBudget(n)`：两条通道对同一规模耐心一致

## 四、拆除的补丁（重要）

此前为绕开行号漂移加了两层补丁：①投后拉 `queue?offset=start&size=1` 比对 `songId`，不一致就②回落推 2MB 整队。

**判定：补丁比问题本身更糟** —— 它把「服务端明确拒绝」退化成「整队重推」，用户观感是音箱先响一下又重来；且把几百字节的请求变成 MB 级上行。**已全部删除。**

正确姿势是**用身份从根上消除歧义**，而不是事后校验行号猜得对不对。

## 五、另一处逻辑修正

`playEffectiveSong` 的单曲判据 `queue.length <= 1` **是错的**。

**「单曲路径」≠「歌单里只有一首」**，而是**手上没有服务端能自行解析的队列上下文**。
→ 改为 `hasQueueContext = queue != null && queue.length > 1`。
歌单页只播一首时走的是 `playEffectiveQueue(type=playlist)`，与本函数无关。

## 六、守卫

| 仓库 | 文件 | 内容 |
| --- | --- | --- |
| 后端 | `tests/routes/playStartLocator.test.ts` | 4 例：命中定位 / 未命中 404 / startIndex 兼容 / 同时传以身份优先 |
| 客户端 | `test/providers/cast_peer_provider_test.dart` | 44 例：新增 songId 定位、无槽位往返、按身份对齐镜像 |

**变异验证**：把后端 songId 分支改成 `if (false)` → 守卫立即变红（已实测）。

## 七、验证基线

| 项 | 结果 |
| --- | --- |
| 客户端 `flutter analyze` | **0 error**（154 条存量 info） |
| 客户端全量 `flutter test` | **587/587 通过** |
| 客户端发版守卫 | interaction_feedback ✅ / gpu_guard_scan ✅ / check_workflow_yaml ✅ / check-l10n --gate-cjk ✅ |
| 后端 `tsc --noEmit` | **0 error** |
| 后端 `vitest run` | **799/799 通过**（新增 4 例） |
| CI | v4.3.37 五条 workflow / v2.3.22 build-and-push（构建中） |

## 八、遗留（不阻塞）

- **悬空 `playlistSongs`**：`songs` 行已删但歌单条目还在 → 服务端队列少 1 首。songId 定位下**不再影响起点正确性**（找的是「这首歌」而非「第 N 位」）。属数据卫生，可选加固。
- **`GET /v1/peers/:id/queue` 轻量轮询**：接口本就支持 `offset`/`size`（实测 100 首：26KB → 546B ≈48×），纯客户端可改，但需同步更新既有 `queuePath()` 测试桩 —— 已报备，待拍板。
